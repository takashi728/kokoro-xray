#!/usr/bin/env bash
# kokoro-xray — node health status

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/caddy.sh"

kokoro_health_kernel_cve() {
    local id="${KOKORO_OS_ID:-}" ver="${KOKORO_OS_VER:-}"
    local rel base abi safe="" safe_abi="" fixed=false mptcp migrate
    if [[ -z "$id" ]]; then
        if [[ -f /etc/os-release ]]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            id="${ID:-}"
            ver="${VERSION_ID:-}"
        fi
    fi
    rel="$(uname -r)"
    case "$id:$ver" in
        debian:12) safe="6.1.190" ;;
        debian:13) safe="6.12.113" ;;
        ubuntu:22.04) safe="5.15.0" safe_abi="203" ;;
        ubuntu:24.04) safe="6.8.0" safe_abi="149" ;;
        ubuntu:26.04) safe="7.0.0" safe_abi="43" ;;
    esac
    [[ -n "$safe" ]] || return 0
    if [[ "$id" == "ubuntu" && "$rel" == *-* ]]; then
        base="${rel%%-*}"
        abi="${rel#*-}"
        abi="${abi%%[!0-9]*}"
        if [[ "$base" == "$safe" && "$abi" =~ ^[0-9]+$ && "$abi" -ge "$safe_abi" ]]; then
            fixed=true
        elif [[ "$base" != "$safe" ]] &&
             [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
             kokoro_version_ge "$base" "$safe"; then
            fixed=true
        fi
    else
        rel="${rel%%-*}"
        rel="${rel%%+*}"
        kokoro_version_ge "$rel" "$safe" && fixed=true
    fi
    mptcp="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo unknown)"
    migrate="$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo unknown)"
    [[ "$fixed" == "true" ]] ||
    echo "kernel:   ${rel} is below the CVE-2026-98432 fix ${safe}${safe_abi:+-$safe_abi} (mptcp=${mptcp}, migrate_req=${migrate})"
}

kokoro_health() {
    local role
    role="$(kokoro_cfg '.role')"

    echo "role:     $(kokoro_cfg '.role')"
    echo "mode:     $(kokoro_cfg '.inbound.mode')"
    echo "transport: $(kokoro_cfg '.inbound.transport // "xhttp"')"
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
        kokoro_health_kernel_cve
        echo "vless enc: $(kokoro_cfg '.inbound.vless_encryption.enabled // false')"
        echo "hysteria:  $(kokoro_cfg '.inbound.hysteria.enabled // false')"
        if kokoro_raw_tls_enabled; then
            echo "fallback: $(systemctl is-active kokoro-fallback.service 2>/dev/null || echo unknown)"
            echo "raw TLS:  TLS + Vision; VLESS payload encryption off (fallback requirement)"
        fi
        if [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]]; then
            echo "hy2 domain: $(kokoro_cfg '.inbound.hysteria.domain')"
            echo "hy2 ports:  $(kokoro_cfg '.inbound.hysteria.ports')/udp"
            echo "hy2 cc:     $(kokoro_cfg '.inbound.hysteria.congestion') (configured, userspace QUIC)"
            if [[ "$(kokoro_cfg '.inbound.hysteria.congestion')" == "bbr" ]]; then
                echo "hy2 bbr:    $(kokoro_cfg '.inbound.hysteria.bbr_profile')"
            fi
        fi
        if kokoro_caddy_required; then
            echo "caddy:    $(systemctl is-active caddy 2>/dev/null || echo unknown)"
        fi
        if [[ "$mode" == "tls" && "$(kokoro_cfg '.inbound.transport // "xhttp"')" == xhttp ]]; then
            echo
            echo -e "${YELLOW}${BOLD}TLS mode client note${NC}"
            echo -e "${RED}Please use HApp or another client that supports JSON copy-paste input.${NC}"
            echo "Generate the full client JSON with: kokoro-xray link --json tls"
        fi
        if [[ "$(kokoro_cfg '.multinode.enabled')" == "true" ]]; then
            local ip port
            ip="$(kokoro_cfg '.multinode.exit_ip')"
            port="$(kokoro_cfg '.multinode.exit_port')"
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
        if [[ "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
            echo "tor:      $(systemctl is-active tor 2>/dev/null || echo unknown)"
        fi
    fi
}
