#!/usr/bin/env bash
# kokoro-xray — interactive edge onboarding

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

kokoro_raw_tls_domain_check() {
    local domain="$1" ip ips
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
    ip="${KOKORO_PUBLIC_ADDRESS:-}"
    [[ -n "$ip" ]] || ip="$(curl -4 -fsS --connect-timeout 3 --max-time 8 https://api.ipify.org)" || return 1
    ips="$(timeout 8 getent ahostsv4 "$domain" | awk '{print $1}' | sort -u)"
    [[ -n "$ip" && "$ips" == "$ip" ]]
}

kokoro_onboard_reality_target() {
    local do_scan="$1" sni
    source "${KOKORO_ROOT}/lib/reality-scan.sh"
    if [[ "$do_scan" == "true" ]]; then
        if kokoro_reality_scan --limit 10 --select; then
            kokoro_log "REALITY target set from scan"
            return 0
        fi
        kokoro_warn "scan found no verified same-ASN target"
    fi
    while read -r -p "Provider-hosted REALITY domain (ownership not required; empty cancels): " sni; do
        [[ -n "$sni" ]] || return 1
        if kokoro_reality_apply_host "$sni"; then
            return 0
        fi
        kokoro_warn "choose another domain hosted in this VPS's ASN"
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
                kokoro_die "RAW TLS requires a DNS-only domain resolving to this VPS"
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
            kokoro_raw_tls_domain_check "$cdn" || kokoro_die "domain must resolve directly to this VPS"
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
    kokoro_onboard_outbound_proxy || return 1
    kokoro_onboard_firewall
}

kokoro_onboard_outbound_proxy() {
    [[ -t 0 ]] || return 0
    local choice protocol address port domains user pass proxy tmp
    if [[ "$(kokoro_sec '.outbound_proxy != null')" == true ]]; then
        read -r -p "Custom outbound proxy [keep/edit/remove] (keep): " choice || return 1
        case "${choice,,}" in
            ""|keep) return 0 ;;
            edit) ;;
            remove) kokoro_sec_set '.outbound_proxy' 'null'; return $? ;;
            *) kokoro_die "choose keep, edit, or remove" ;;
        esac
    else
        read -r -p "Use a custom authenticated outbound proxy? [y/N]: " choice || return 1
        [[ "${choice,,}" == y || "${choice,,}" == yes ]] || return 0
    fi

    read -r -p "Proxy type [socks5/http]: " protocol || return 1
    case "${protocol,,}" in
        socks5) protocol=socks ;;
        http) protocol=http ;;
        *) kokoro_die "proxy type must be socks5 or http" ;;
    esac
    read -r -p "Proxy hostname or IP (no scheme or port): " address || return 1
    read -r -p "Proxy port: " port || return 1
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) ||
        kokoro_die "proxy port must be 1-65535"
    read -r -p "Destination domains (comma-separated, includes subdomains): " domains || return 1
    read -r -p "Proxy username: " user || return 1
    read -rs -p "Proxy password (required): " pass || return 1
    printf '\n' >&2

    proxy="$(printf '%s\0' "$address" "$domains" "$user" "$pass" |
        jq -Rse --arg protocol "$protocol" --argjson port "$((10#$port))" '
            split("\u0000") as [$address, $domains, $user, $pass]
            | ($domains | split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | unique) as $domains_list
            | select(($address | test("^([a-zA-Z0-9][a-zA-Z0-9.-]*|[a-fA-F0-9:]*:[a-fA-F0-9:.]*:[a-fA-F0-9:.]*)$"))
                and ($domains_list | length > 0 and all(test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")))
                and ($user | length > 0 and (contains(":") | not))
                and ($pass | length > 0)
                and ($protocol != "socks" or (($user | utf8bytelength) <= 255 and ($pass | utf8bytelength) <= 255)))
            | {protocol: $protocol, address: $address, port: $port, domains: $domains_list, user: $user, pass: $pass}
        ')" || kokoro_die "invalid proxy address, destination domains, or credentials"

    tmp="$(mktemp "${KOKORO_SECRETS}.XXXXXX")" || return 1
    if ! jq --slurpfile proxy /dev/stdin '.outbound_proxy = $proxy[0]' "${KOKORO_SECRETS}" >"$tmp" <<<"$proxy" ||
        ! mv -- "$tmp" "${KOKORO_SECRETS}"; then
        rm -f -- "$tmp"
        kokoro_die "could not save outbound proxy settings"
    fi
    kokoro_state_refresh_sec
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
