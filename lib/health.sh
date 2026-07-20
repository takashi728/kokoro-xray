#!/usr/bin/env bash
# kokoro-xray — node health status

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_health() {
    local role
    role="$(kokoro_cfg '.role')"

    echo "role:     $(kokoro_cfg '.role')"
    echo "mode:     $(kokoro_cfg '.inbound.mode')"
    echo "xray:     $(systemctl is-active xray 2>/dev/null || echo unknown)"

    if [[ -f "${KOKORO_ROOT}/lib/network-tune.sh" ]]; then
        # shellcheck source=lib/network-tune.sh
        source "${KOKORO_ROOT}/lib/network-tune.sh"
        kokoro_network_tune_check >/dev/null 2>&1 \
            && echo "network:  TFO+BBR ok" \
            || echo "network:  tuning suboptimal (run: kokoro-xray tune)"
    fi

    if [[ "$role" == "edge" ]]; then
        local mode
        mode="$(kokoro_cfg '.inbound.mode')"
        echo "vless enc: $(kokoro_cfg '.inbound.vless_encryption.enabled // false')"
        if [[ "$mode" == "tls" || "$mode" == "both" ]]; then
            echo "caddy:    $(systemctl is-active caddy 2>/dev/null || echo unknown)"
        fi
        if [[ "$mode" == "tls" ]]; then
            echo
            echo -e "${YELLOW}${BOLD}TLS mode client note${NC}"
            echo -e "${RED}Please use HApp or another client that supports JSON copy-paste input.${NC}"
            echo "Generate the full client JSON with: kokoro-xray link --json tls"
        fi
        if [[ "$(kokoro_cfg '.multinode.enabled')" == "true" ]]; then
            local ip port
            ip="$(kokoro_cfg '.multinode.exit_ip')"
            port="$(kokoro_cfg '.multinode.exit_port')"
            echo "wg psk:   configured"
            if command -v nc >/dev/null 2>&1; then
                nc -zvu -w 2 "$ip" "$port" 2>/dev/null && echo "exit wg:  udp ${ip}:${port} reachable" \
                    || echo "exit wg:  udp ${ip}:${port} NOT reachable"
            else
                echo "exit wg:  check UDP ${ip}:${port} manually"
            fi
        fi
    fi

    if [[ "$role" == "exit" ]]; then
        echo "wg port:  $(kokoro_cfg '.multinode.exit_port')/udp"
        echo "wg psk:   configured"
        if [[ "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
            echo "tor:      $(systemctl is-active tor 2>/dev/null || echo unknown)"
        fi
    fi
}
