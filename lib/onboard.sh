#!/usr/bin/env bash
# kokoro-xray — interactive edge onboarding

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

kokoro_onboard_edge() {
    local mode cdn email sni dest hy_answer hy_enabled hy_domain hy_ports hy_masquerade

    if [[ ! -t 0 ]]; then
        return 0
    fi

    read -r -p "Inbound mode [reality/tls/both] (both): " mode
    mode="${mode:-both}"
    kokoro_cfg_set_str '.inbound.mode' "$mode"

    if [[ "$mode" == "tls" || "$mode" == "both" ]]; then
        read -r -p "CDN domain (e.g. cdn.example.com): " cdn
        [[ -n "$cdn" ]] && kokoro_cfg_set_str '.inbound.tls.cdn_domain' "$cdn"
        read -r -p "ACME email: " email
        [[ -n "$email" ]] && kokoro_cfg_set_str '.inbound.tls.acme_email' "$email"
        kokoro_warn "Cloudflare: use Full (Strict) SSL; DNS-only during first cert if HTTP-01 fails"
    fi

    if [[ "$mode" == "reality" || "$mode" == "both" ]]; then
        local do_scan=false scan_args=()
        if [[ "${KOKORO_APPLY_EDGE:-}" == "true" ]]; then
            do_scan=true
            kokoro_log "scanning REALITY targets (--apply-edge)..."
        else
            read -r -p "Scan for REALITY target? [Y/n]: " scan_ans
            [[ ! "$scan_ans" =~ ^[Nn]$ ]] && do_scan=true
        fi

        if [[ "$do_scan" == "true" ]]; then
            # shellcheck source=lib/reality-scan.sh
            source "${KOKORO_ROOT}/lib/reality-scan.sh"
            if [[ -t 0 ]]; then
                scan_args=(--limit 10 --select)
            else
                scan_args=(--limit 10 --apply)
            fi
            if kokoro_reality_scan "${scan_args[@]}"; then
                kokoro_log "REALITY target set from scan"
            else
                kokoro_warn "scan found no valid targets — enter manually"
                read -r -p "REALITY SNI [www.sky.com]: " sni
                sni="${sni:-www.sky.com}"
                kokoro_cfg_set '.inbound.reality.server_names' "[\"${sni}\"]"
                read -r -p "REALITY dest [${sni}:443]: " dest
                dest="${dest:-${sni}:443}"
                kokoro_cfg_set_str '.inbound.reality.dest' "$dest"
            fi
        else
            read -r -p "REALITY SNI [www.sky.com]: " sni
            sni="${sni:-www.sky.com}"
            kokoro_cfg_set '.inbound.reality.server_names' "[\"${sni}\"]"
            read -r -p "REALITY dest [${sni}:443]: " dest
            dest="${dest:-${sni}:443}"
            kokoro_cfg_set_str '.inbound.reality.dest' "$dest"
        fi
    fi

    hy_enabled="$(kokoro_cfg '.inbound.hysteria.enabled // false')"
    if [[ "$hy_enabled" == "true" ]]; then
        read -r -p "Keep Hysteria2 enabled? [Y/n]: " hy_answer
        if [[ "$hy_answer" =~ ^[Nn]$ ]]; then
            kokoro_cfg_set '.inbound.hysteria.enabled' 'false'
        fi
    else
        read -r -p "Enable Hysteria2 (UDP + port hopping)? [y/N]: " hy_answer
        [[ "$hy_answer" =~ ^[Yy]$ ]] && kokoro_cfg_set '.inbound.hysteria.enabled' 'true'
    fi

    if [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]]; then
        read -r -p "Hysteria2 direct domain (DNS-only, not CDN-proxied): " hy_domain
        hy_domain="${hy_domain,,}"
        [[ -n "$hy_domain" ]] && kokoro_cfg_set_str '.inbound.hysteria.domain' "$hy_domain"

        if [[ -z "$(kokoro_cfg '.inbound.tls.acme_email')" ]]; then
            read -r -p "ACME email: " email
            [[ -n "$email" ]] && kokoro_cfg_set_str '.inbound.hysteria.acme_email' "$email"
        else
            kokoro_cfg_set_str '.inbound.hysteria.acme_email' "$(kokoro_cfg '.inbound.tls.acme_email')"
        fi

        read -r -p "Hysteria2 UDP ports [$(kokoro_cfg '.inbound.hysteria.ports')]: " hy_ports
        hy_ports="$(printf '%s' "$hy_ports" | tr -d '[:space:]')"
        [[ -n "$hy_ports" ]] && kokoro_cfg_set_str '.inbound.hysteria.ports' "$hy_ports"
        read -r -p "Masquerade website [$(kokoro_cfg '.inbound.hysteria.masquerade')]: " hy_masquerade
        hy_masquerade="${hy_masquerade,,}"
        [[ -n "$hy_masquerade" ]] && kokoro_cfg_set_str '.inbound.hysteria.masquerade' "$hy_masquerade"
        kokoro_warn "Hysteria2 domain must resolve directly to this VPS; ordinary CDN proxying cannot carry it"
    fi

    kokoro_cfg_set '.tor.enabled' 'false'
    kokoro_onboard_firewall
}

kokoro_onboard_firewall() {
    local ans ssh extra detected json_arr
    if [[ ! -t 0 ]]; then
        return 0
    fi

    read -r -p "Enable UFW firewall? [Y/n]: " ans
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        kokoro_cfg_set '.firewall.enabled' 'false'
        return 0
    fi
    kokoro_cfg_set '.firewall.enabled' 'true'

    detected="$(bash -c "source '${KOKORO_ROOT}/lib/firewall.sh'; kokoro_firewall_detect_ssh")"
    read -r -p "SSH port [auto/${detected}]: " ssh
    if [[ -n "$ssh" ]]; then
        kokoro_cfg_set '.firewall.ssh_port' "$ssh"
    else
        kokoro_cfg_set '.firewall.ssh_port' '0'
    fi

    read -r -p "Extra allow ports (e.g. 5555,5000-5010): " extra
    if [[ -z "$extra" ]]; then
        kokoro_cfg_set '.firewall.extra_allow' '[]'
        return 0
    fi

    json_arr="$(printf '%s' "$extra" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | awk 'NF {printf "%s\"%s\"", (n++?",":""), $0}')"
    kokoro_cfg_set '.firewall.extra_allow' "[${json_arr}]"
}
