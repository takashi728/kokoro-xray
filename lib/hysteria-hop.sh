#!/usr/bin/env bash
# Remote port hopping must reach one QUIC listener, not independent listeners.
source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"

kokoro_hysteria_hop_stop() {
    local bin hook
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        for hook in PREROUTING OUTPUT; do
            while "$bin" -w 5 -t nat -C "$hook" -p udp -m addrtype --dst-type LOCAL -j KOKORO_HY2 2>/dev/null; do
                "$bin" -w 5 -t nat -D "$hook" -p udp -m addrtype --dst-type LOCAL -j KOKORO_HY2 || return 1
            done
        done
        if "$bin" -w 5 -t nat -L KOKORO_HY2 >/dev/null 2>&1; then
            "$bin" -w 5 -t nat -F KOKORO_HY2 || return 1
            "$bin" -w 5 -t nat -X KOKORO_HY2 || return 1
        fi
    done
}

kokoro_hysteria_hop_rules() {
    local ports primary item spec bin
    local -a items
    ports="$(kokoro_cfg '.inbound.hysteria.ports' | tr -d '[:space:]')"
    primary="${ports%%,*}"
    primary="${primary%%-*}"
    kokoro_firewall_valid_port "$primary" || return 1
    IFS=',' read -ra items <<<"$ports"
    for item in "${items[@]}"; do
        kokoro_firewall_parse_allow "${item}/udp" >/dev/null || return 1
    done
    for bin in iptables ip6tables; do
        "$bin" -w 5 -t nat -N KOKORO_HY2 || return 1
        for item in "${items[@]}"; do
            [[ "$item" != "$primary" ]] || continue
            spec="$(kokoro_firewall_parse_allow "${item}/udp")" || return 1
            "$bin" -w 5 -t nat -A KOKORO_HY2 -p udp --dport "${spec%/udp}" -j REDIRECT --to-ports "$primary" || return 1
        done
        "$bin" -w 5 -t nat -A PREROUTING -p udp -m addrtype --dst-type LOCAL -j KOKORO_HY2 || return 1
    done
}

kokoro_hysteria_hop_start() {
    kokoro_need_root
    kokoro_hysteria_hop_stop || return 1
    [[ "$(kokoro_cfg '.role')" == edge && "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == true ]] || return 0
    if ! kokoro_hysteria_hop_rules; then
        kokoro_hysteria_hop_stop
        return 1
    fi
}

kokoro_hysteria_hop_sync() {
    local name=kokoro-hysteria-hop.service unit_dir unit
    unit_dir="$(kokoro_systemd_unit_dir)"
    if [[ "$(kokoro_cfg '.role')" != edge || "$(kokoro_cfg '.inbound.hysteria.enabled // false')" != true ]]; then
        if [[ -f "$unit_dir/$name" ]]; then
            systemctl disable --now "$name" || return 1
            rm -f "$unit_dir/$name"
            systemctl daemon-reload
        fi
        return 0
    fi
    kokoro_need_cmd iptables
    kokoro_need_cmd ip6tables
    kokoro_require_safe_path 'repository' "$KOKORO_ROOT"
    kokoro_require_safe_path 'HOME' "$HOME"
    unit="[Unit]
Description=Hysteria2 UDP hopping redirects (kokoro-xray)
After=ufw.service
Before=xray.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=${HOME}
ExecStart=/usr/bin/bash ${KOKORO_ROOT}/lib/hysteria-hop.sh start
ExecStop=/usr/bin/bash ${KOKORO_ROOT}/lib/hysteria-hop.sh stop

[Install]
WantedBy=multi-user.target"
    kokoro_install_systemd_unit "$name" "$unit"
    systemctl daemon-reload
    systemctl enable "$name" >/dev/null || return 1
    systemctl restart "$name"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    kokoro_need_root
    case "${1:-}" in
        start) kokoro_hysteria_hop_start ;;
        stop) kokoro_hysteria_hop_stop ;;
        *) kokoro_die 'usage: hysteria-hop.sh start|stop' ;;
    esac
fi
