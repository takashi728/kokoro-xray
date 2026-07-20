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
source "${KOKORO_ROOT}/lib/relay.sh"
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

    if [[ -z "$(kokoro_cfg '.multinode.edge_ip')" || "$(kokoro_cfg '.multinode.edge_ip')" == "null" ]]; then
        if [[ -t 0 ]]; then
            local edge_ip
            read -r -p "Edge public IPv4 (leave empty to pair later): " edge_ip
            [[ -n "$edge_ip" ]] && kokoro_cfg_set_str '.multinode.edge_ip' "$edge_ip"
        else
            kokoro_warn "multinode.edge_ip not set - run: kokoro-xray pair"
        fi
    fi

    if [[ -z "$(kokoro_cfg '.multinode.edge_ip')" || "$(kokoro_cfg '.multinode.edge_ip')" == "null" ]]; then
        kokoro_warn "exit configured but not applied - missing edge public IPv4"
        kokoro_warn "install edge, run kokoro-xray pair, then apply on exit"
    else
        kokoro_apply
    fi
    kokoro_network_tune || true
    echo ""
    echo "=== Exit relay bundle (paste on edge) ==="
    kokoro_relay_export_bundle
    kokoro_log "allow TCP $(kokoro_cfg '.multinode.exit_port') from the edge IPv4 only"
}

kokoro_exit_install
