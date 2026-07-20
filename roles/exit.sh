#!/usr/bin/env bash
# kokoro-xray — exit node setup

export KOKORO_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
KEEP_SECRETS=false
FORCE_SECRETS=false

for arg in "$@"; do
    case "$arg" in
        --keep-secrets) KEEP_SECRETS=true ;;
        --force-secrets) FORCE_SECRETS=true ;;
    esac
done

source "${KOKORO_ROOT}/lib/common.sh"
source "${KOKORO_ROOT}/lib/os.sh"
source "${KOKORO_ROOT}/lib/xray.sh"
source "${KOKORO_ROOT}/lib/keys.sh"
source "${KOKORO_ROOT}/lib/onboard.sh"
source "${KOKORO_ROOT}/lib/apply.sh"
source "${KOKORO_ROOT}/lib/network-tune.sh"

kokoro_exit_install() {
    kokoro_need_root
    kokoro_ensure_state
    kokoro_cfg_set_str '.role' 'exit'
    kokoro_onboard_firewall

    kokoro_install_deps
    kokoro_xray_install

    if [[ "$FORCE_SECRETS" == "true" ]]; then
        kokoro_gen_secrets
    elif [[ "$KEEP_SECRETS" == "true" ]] && kokoro_secrets_exist; then
        kokoro_log "keeping existing secrets"
    else
        if ! kokoro_secrets_exist; then
            kokoro_gen_secrets
        else
            kokoro_log "keeping existing secrets"
        fi
    fi
    kokoro_ensure_wg_preshared_key

    if [[ -z "$(kokoro_cfg '.multinode.peer_edge_pubkey')" || "$(kokoro_cfg '.multinode.peer_edge_pubkey')" == "null" ]]; then
        if [[ -t 0 ]]; then
            local epub
            read -r -p "Edge WG public key (leave empty to pair later): " epub
            [[ -n "$epub" ]] && kokoro_cfg_set_str '.multinode.peer_edge_pubkey' "$epub"
        else
            kokoro_warn "multinode.peer_edge_pubkey not set — run: kokoro-xray pair"
        fi
    fi

    if [[ -z "$(kokoro_cfg '.multinode.peer_edge_pubkey')" || "$(kokoro_cfg '.multinode.peer_edge_pubkey')" == "null" ]]; then
        kokoro_warn "exit configured but not applied — missing edge WG public key"
        kokoro_warn "install edge, run kokoro-xray pair, then run kokoro-xray apply on exit"
    else
        kokoro_apply
    fi
    kokoro_network_tune || true
    kokoro_log "exit pubkey (paste on edge): $(kokoro_sec '.multinode.exit_wg_pubkey')"
    kokoro_log "exit PSK (paste on edge): $(kokoro_sec '.multinode.wg_preshared_key')"
    kokoro_log "open UDP $(kokoro_cfg '.multinode.exit_port') on firewall"
}

kokoro_exit_install
