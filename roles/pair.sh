#!/usr/bin/env bash
# kokoro-xray - exchange high-assurance relay information

export KOKORO_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
source "${KOKORO_ROOT}/lib/common.sh"
source "${KOKORO_ROOT}/lib/apply.sh"
source "${KOKORO_ROOT}/lib/relay.sh"

kokoro_pair() {
    local role
    kokoro_ensure_state
    role="$(kokoro_cfg '.role')"

    case "$role" in
        edge)
            local bundle
            read -r -s -p "Paste exit relay bundle: " bundle
            echo
            kokoro_relay_import_bundle "$bundle"
            kokoro_apply
            echo ""
            echo "=== Give this to exit node ==="
            echo "edge_ip=$(kokoro_relay_public_ipv4)"
            ;;
        exit)
            local edge_ip
            read -r -p "Edge public IPv4: " edge_ip
            kokoro_cfg_set_str '.multinode.edge_ip' "$edge_ip"
            kokoro_apply
            echo ""
            echo "=== Give this to edge node ==="
            kokoro_relay_export_bundle
            ;;
        *)
            kokoro_die "set role first (run edge or exit install)"
            ;;
    esac
}

kokoro_pair
