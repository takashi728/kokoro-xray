#!/usr/bin/env bash
# kokoro-xray — interactive edge onboarding

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

kokoro_raw_tls_domain_check() {
    local domain="$1" ip ips
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
    source "${KOKORO_ROOT}/lib/reality-asn.sh"
    ip="${KOKORO_PUBLIC_ADDRESS:-}"
    [[ -n "$ip" ]] || ip="$(curl -4 -fsS --connect-timeout 3 --max-time 8 https://api.ipify.org)" || return 1
    kokoro_reality_ip_literal "$ip" || return 1
    ips="$(timeout 8 getent ahosts "$domain" | awk '{print $1}' | sort -u)"
    grep -Fx -- "$ip" <<<"$ips" >/dev/null || return 1
    kokoro_reality_cdn_screen "$domain" "$ips"
}

kokoro_onboard_reality_target() {
    local do_scan="$1" sni
    source "${KOKORO_ROOT}/lib/reality-scan.sh"
    if [[ "$do_scan" == "true" ]]; then
        if kokoro_reality_scan --limit 10 --select; then
            kokoro_log "REALITY target set from scan"
            return 0
        fi
        kokoro_warn "scan found no verified same-ASN target passing CDN screening"
    fi
    while read -r -p "Direct, non-CDN provider-hosted REALITY domain (empty cancels): " sni; do
        [[ -n "$sni" ]] || return 1
        if kokoro_reality_apply_host "$sni"; then
            return 0
        fi
        kokoro_warn "choose a direct domain in this VPS's ASN; CDN targets and failed checks are rejected"
    done
    return 1
}

kokoro_onboard_edge() {
    local mode cdn email hy_answer hy_enabled hy_domain hy_ports hy_masquerade transport default_transport default_mode

    if [[ ! -t 0 ]]; then
        mode="$(kokoro_cfg '.inbound.mode')"
        if [[ "$mode" == "reality" || "$mode" == "both" ]]; then
            source "${KOKORO_ROOT}/lib/reality-scan.sh"
            kokoro_reality_apply_host "$(kokoro_cfg '.inbound.reality.server_names[0]')" ||
                kokoro_die "noninteractive REALITY setup requires a verified same-ASN target"
        fi
        if kokoro_raw_tls_enabled; then
            kokoro_raw_tls_domain_check "$(kokoro_tls_domain)" ||
                kokoro_die "RAW TLS requires a direct domain resolving to this VPS; CDN checks failed"
        fi
        return 0
    fi

    default_transport="$(kokoro_cfg '.inbound.transport // "xhttp"')"
    [[ -n "$(kokoro_sec '.inbound.uuid')" ]] || default_transport=raw
    read -r -p "Transport [raw=CN performance/xhttp=CDN] (${default_transport}): " transport
    transport="${transport:-$default_transport}"
    [[ "$transport" == raw || "$transport" == xhttp ]] || kokoro_die "transport must be raw or xhttp"
    kokoro_cfg_set_str '.inbound.transport' "$transport"
    default_mode="$(kokoro_cfg '.inbound.mode')"
    if [[ "$transport" == raw && -z "$(kokoro_sec '.inbound.uuid')" ]]; then default_mode=reality; fi
    read -r -p "Inbound mode [reality/tls/both] (${default_mode}): " mode
    mode="${mode:-$default_mode}"
    kokoro_cfg_set_str '.inbound.mode' "$mode"

    if [[ "$mode" == "tls" || "$mode" == "both" ]]; then
        if [[ "$transport" == raw ]]; then
            kokoro_warn "RAW TLS fallback excludes VLESS payload encryption; TLS and Vision remain active"
            read -r -p "Direct TLS domain (DNS-only, pointing to this VPS): " cdn
        else
            read -r -p "CDN domain (e.g. cdn.example.com): " cdn
        fi
        cdn="${cdn,,}"
        if [[ "$transport" == raw ]]; then
            [[ -n "$cdn" ]] || cdn="$(kokoro_cfg '.inbound.tls.domain')"
            kokoro_log "checking direct TLS domain..."
            kokoro_raw_tls_domain_check "$cdn" || kokoro_die "domain must resolve directly to this VPS and pass CDN screening"
            kokoro_cfg_set_str '.inbound.tls.domain' "$cdn"
        else
            [[ -n "$cdn" ]] && kokoro_cfg_set_str '.inbound.tls.cdn_domain' "$cdn"
        fi
        read -r -p "ACME email: " email
        [[ -n "$email" ]] && kokoro_cfg_set_str '.inbound.tls.acme_email' "$email"
        if [[ "$transport" == xhttp ]]; then
            kokoro_warn "Cloudflare: use Full (Strict) SSL; DNS-only during first cert if HTTP-01 fails"
        fi
    fi

    if [[ "$mode" == "reality" || "$mode" == "both" ]]; then
        local do_scan=false
        if [[ "${KOKORO_APPLY_EDGE:-}" == "true" ]]; then
            do_scan=true
            kokoro_log "scanning REALITY targets (--apply-edge)..."
        else
            read -r -p "Scan for REALITY target? [Y/n]: " scan_ans
            [[ ! "$scan_ans" =~ ^[Nn]$ ]] && do_scan=true
        fi

        kokoro_onboard_reality_target "$do_scan" ||
            kokoro_die "REALITY setup stopped without a verified same-ASN target"
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
