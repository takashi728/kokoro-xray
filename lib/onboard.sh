#!/usr/bin/env bash
# kokoro-xray — interactive edge onboarding

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

kokoro_onboard_edge() {
    local mode cdn email sni dest

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

    kokoro_cfg_set '.tor.enabled' 'false'
    kokoro_onboard_static_proxy
    kokoro_onboard_firewall
}

kokoro_onboard_static_proxy() {
    local ans proto addr port user pass
    if [[ ! -t 0 ]]; then
        return 0
    fi

    read -r -p "Do you have a static proxy? [y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        kokoro_cfg_set '.static_proxy.enabled' 'false'
        return 0
    fi

    kokoro_cfg_set '.static_proxy.enabled' 'true'
    read -r -p "Static proxy protocol [socks/http] (socks): " proto
    kokoro_cfg_set_str '.static_proxy.protocol' "${proto:-socks}"
    read -r -p "Static proxy address: " addr
    [[ -n "$addr" ]] && kokoro_cfg_set_str '.static_proxy.address' "$addr"
    read -r -p "Static proxy port: " port
    [[ -n "$port" ]] && kokoro_cfg_set '.static_proxy.port' "$port"
    read -r -p "Static proxy username (empty = none): " user
    if [[ -n "$user" ]]; then
        kokoro_sec_set_str '.static_proxy.username' "$user"
        read -r -s -p "Static proxy password: " pass && echo
        kokoro_sec_set_str '.static_proxy.password' "${pass:-}"
    fi
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
