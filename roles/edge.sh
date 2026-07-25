#!/usr/bin/env bash
# kokoro-xray — edge node setup

export KOKORO_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
KEEP_SECRETS=false
FORCE_SECRETS=false
KOKORO_APPLY_EDGE=false

for arg in "$@"; do
    case "$arg" in
        --keep-secrets) KEEP_SECRETS=true ;;
        --force-secrets) FORCE_SECRETS=true ;;
        --apply-edge) KOKORO_APPLY_EDGE=true ;;
    esac
done
export KOKORO_APPLY_EDGE

source "${KOKORO_ROOT}/lib/common.sh"
source "${KOKORO_ROOT}/lib/os.sh"
source "${KOKORO_ROOT}/lib/xray.sh"
source "${KOKORO_ROOT}/lib/caddy.sh"
source "${KOKORO_ROOT}/lib/keys.sh"
source "${KOKORO_ROOT}/lib/onboard.sh"
source "${KOKORO_ROOT}/lib/cf.sh"
source "${KOKORO_ROOT}/lib/apply.sh"
source "${KOKORO_ROOT}/lib/network-tune.sh"

kokoro_edge_install() {
    local mode
    kokoro_need_root
    kokoro_install_deps
    kokoro_ensure_state
    kokoro_cfg_set_str '.role' 'edge'

    kokoro_onboard_edge
    kokoro_xray_install

    if [[ "$FORCE_SECRETS" == "true" ]]; then
        kokoro_warn "rotating secrets — existing client links will break"
        kokoro_gen_secrets
    elif [[ "$KEEP_SECRETS" == "true" ]] && kokoro_secrets_exist; then
        kokoro_log "keeping existing secrets"
    else
        if ! kokoro_secrets_exist; then
            kokoro_gen_secrets
        elif [[ -t 0 ]]; then
            read -r -p "Secrets exist. Regenerate? [y/N] " ans
            [[ "$ans" =~ ^[Yy]$ ]] && kokoro_gen_secrets || kokoro_log "keeping existing secrets"
        else
            kokoro_log "keeping existing secrets"
        fi
    fi
    mode="$(kokoro_cfg '.inbound.mode')"
    if kokoro_caddy_required; then
        kokoro_caddy_install
        [[ "$mode" == "tls" || "$mode" == "both" ]] && kokoro_cf_dns01_hint
    fi

    if [[ -t 0 && "$(kokoro_cfg '.multinode.enabled')" != "true" ]]; then
        read -r -p "Enable multinode WG to exit? [y/N] " mn
        if [[ "$mn" =~ ^[Yy]$ ]]; then
            local ip pub
            read -r -p "Exit node IP: " ip
            read -r -p "Exit WG public key: " pub
            kokoro_cfg_set_str '.multinode.exit_ip' "$ip"
            kokoro_cfg_set_str '.multinode.peer_exit_pubkey' "$pub"
            kokoro_cfg_set '.multinode.enabled' 'true'
        fi
    fi

    kokoro_apply
    kokoro_network_tune || true
    if [[ "$(kokoro_cfg '.multinode.enabled')" == "true" ]]; then
        kokoro_log "edge pubkey (paste on exit): $(kokoro_sec '.multinode.edge_wg_pubkey')"
    fi
}

kokoro_edge_install
