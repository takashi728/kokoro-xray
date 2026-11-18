#!/usr/bin/env bash
# REALITY target network checks, shared by scans and manual selection.

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_reality_ip_literal() {
    local ip="$1" octet count=0
    local -a octets
    if [[ "$ip" == *:* ]]; then
        [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" != *:::* ]] || return 1
        IFS=: read -ra octets <<<"$ip"
        for octet in "${octets[@]}"; do
            [[ "${#octet}" -le 4 ]] || return 1
            [[ -z "$octet" ]] || count=$((count + 1))
        done
        if [[ "$ip" == *::* ]]; then
            [[ "${ip#*::}" != *::* ]] && (( count < 8 ))
        else
            [[ "$ip" != :* && "$ip" != *: ]] && (( count == 8 ))
        fi
    else
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        IFS=. read -ra octets <<<"$ip"
        for octet in "${octets[@]}"; do
            [[ "${#octet}" -le 3 ]] && (( 10#$octet <= 255 )) || return 1
        done
    fi
}

kokoro_reality_endpoint() {
    if [[ "$1" == *:* ]]; then printf '[%s]:443\n' "$1"
    else printf '%s:443\n' "$1"; fi
}

kokoro_reality_lookup_asns() {
    local ip="$1" response cache="" tmp
    kokoro_reality_ip_literal "$ip" || return 1
    if [[ -n "${KOKORO_REALITY_ASN_CACHE:-}" ]]; then
        cache="${KOKORO_REALITY_ASN_CACHE}/${ip//:/_}"
        if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi
    fi
    response="$(curl -fsS --connect-timeout 3 --max-time 8 --get \
        --data-urlencode "resource=$ip" \
        https://stat.ripe.net/data/network-info/data.json)" || return 1
    response="$(jq -er '
        select(.status == "ok") | .data.asns
        | select(type == "array" and length > 0)
        | map(tostring) | select(all(.[]; test("^[0-9]+$")))
        | unique | join(",")
    ' <<<"$response")" || return 1
    [[ -n "$response" ]] || return 1
    if [[ -n "$cache" ]]; then
        tmp="$(mktemp "${cache}.XXXXXX")" || return 1
        printf '%s\n' "$response" >"$tmp"
        mv "$tmp" "$cache"
    fi
    printf '%s\n' "$response"
}

kokoro_reality_network_init() {
    local ip asns
    ip="${KOKORO_PUBLIC_ADDRESS:-}"
    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --connect-timeout 3 --max-time 8 https://api.ipify.org)" || {
            kokoro_warn "cannot detect public IPv4; set KOKORO_PUBLIC_ADDRESS to this VPS's public IP"
            return 1
        }
    fi
    kokoro_reality_ip_literal "$ip" || {
        kokoro_warn "REALITY ASN checks require a literal public IP: $ip"
        return 1
    }
    asns="$(kokoro_reality_lookup_asns "$ip")" || {
        kokoro_warn "cannot establish announcing ASN for $ip; target selection stopped"
        return 1
    }
    export KOKORO_REALITY_SERVER_IP="$ip" KOKORO_REALITY_SERVER_ASNS="$asns"
}

kokoro_reality_target_ip() {
    local host="$1" ips ip asns asn selected=""
    [[ -n "${KOKORO_REALITY_SERVER_ASNS:-}" ]] || return 1
    ips="$(timeout "${KOKORO_REALITY_SCAN_TIMEOUT:-8}" getent ahosts "$host" |
        awk '{print $1}' | sort -u)"
    [[ -n "$ips" ]] || return 1
    while IFS= read -r ip; do
        kokoro_reality_ip_literal "$ip" || return 1
        [[ "$ip" != "$KOKORO_REALITY_SERVER_IP" ]] || return 1
        asns="$(kokoro_reality_lookup_asns "$ip")" || return 1
        local -a origins
        IFS=, read -ra origins <<<"$asns"
        for asn in "${origins[@]}"; do
            [[ ",${KOKORO_REALITY_SERVER_ASNS}," == *",${asn},"* ]] || return 1
        done
        # Prefer IPv4, matching the default client address family.
        if [[ -z "$selected" || ( "$selected" == *:* && "$ip" != *:* ) ]]; then
            selected="$ip"
        fi
    done <<<"$ips"
    printf '%s\n' "$selected"
}

kokoro_reality_provider_hosts() {
    local host
    # PTR suffixes are candidate hints only; they still need ASN and TLS checks.
    while IFS= read -r host; do
        host="${host%.}"
        while [[ "$host" == *.* ]]; do
            printf '%s\n' "$host" "www.$host"
            host="${host#*.}"
        done
    done < <(timeout "${KOKORO_REALITY_SCAN_TIMEOUT:-8}" getent hosts \
        "$KOKORO_REALITY_SERVER_IP" 2>/dev/null | awk '{for (i=2;i<=NF;i++) print $i}')
}
