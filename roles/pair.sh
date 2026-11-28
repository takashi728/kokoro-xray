#!/usr/bin/env bash
# kokoro-xray — exchange WG peer keys between edge and exit

export KOKORO_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
source "${KOKORO_ROOT}/lib/common.sh"
source "${KOKORO_ROOT}/lib/apply.sh"

kokoro_pair_exit_ip() {
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    local ipv4="^${octet}(\\.${octet}){3}$" ip addresses
    local -a candidates
    if ip="$(curl -4 -fsSL --proto '=https' --proto-redir '=https' --max-time 5 \
        https://ifconfig.me 2>/dev/null)" && [[ "$ip" =~ $ipv4 ]]; then
        printf '%s\n' "$ip"
        return 0
    fi
    addresses="$(hostname -I 2>/dev/null)" || return 1
    read -ra candidates <<<"$addresses"
    for ip in "${candidates[@]}"; do
        if [[ "$ip" =~ $ipv4 ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

kokoro_pair() {
    local role
    kokoro_ensure_state
    role="$(kokoro_cfg '.role')"

    case "$role" in
        edge)
            local ip pub
            read -r -p "Exit node IP: " ip
            read -r -p "Exit WG public key: " pub
            kokoro_cfg_set_str '.multinode.exit_ip' "$ip"
            kokoro_cfg_set_str '.multinode.peer_exit_pubkey' "$pub"
            kokoro_cfg_set '.multinode.enabled' 'true'
            kokoro_apply
            echo ""
            echo "=== Give this to exit node ==="
            echo "edge_wg_pubkey=$(kokoro_sec '.multinode.edge_wg_pubkey')"
            ;;
        exit)
            local epub exit_ip
            read -r -p "Edge WG public key: " epub
            kokoro_cfg_set_str '.multinode.peer_edge_pubkey' "$epub"
            kokoro_apply
            echo ""
            echo "=== Give this to edge node ==="
            echo "exit_wg_pubkey=$(kokoro_sec '.multinode.exit_wg_pubkey')"
            if exit_ip="$(kokoro_pair_exit_ip)"; then
                printf 'exit_ip=%s\n' "$exit_ip"
            else
                kokoro_warn "Could not detect an IPv4 address. Give the edge node this exit node's reachable IPv4 address manually."
            fi
            ;;
        *)
            kokoro_die "set role first (run edge or exit install)"
            ;;
    esac
}

kokoro_pair
