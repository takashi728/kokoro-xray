#!/usr/bin/env bash
# kokoro-xray — validate intent before render

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/firewall.sh"

kokoro_preflight() {
    local role mode
    role="$(kokoro_cfg '.role')"
    mode="$(kokoro_cfg '.inbound.mode')"

    kokoro_preflight_paths
    [[ -n "$role" && "$role" != "null" ]] || kokoro_die "role not set (edge or exit)"

    case "$role" in
        edge) kokoro_preflight_edge "$mode" ;;
        exit) kokoro_preflight_exit ;;
        *) kokoro_die "unknown role: $role" ;;
    esac

    if [[ "$(kokoro_cfg '.firewall.enabled // false')" == "true" ]]; then
        kokoro_firewall_validate_extra
    fi

    kokoro_check_secret_perms
}

kokoro_preflight_paths() {
    local key value
    for key in \
        '.paths.xray_config' \
        '.paths.xray_bin' \
        '.paths.geo_dir'; do
        value="$(kokoro_cfg "$key")"
        [[ -n "$value" && "$value" != "null" ]] || kokoro_die "missing required config path: $key"
    done
}

kokoro_preflight_edge() {
    local mode="$1" cdn decryption encryption
    case "$mode" in
        reality|tls|both) ;;
        *) kokoro_die "invalid inbound.mode: $mode" ;;
    esac

    [[ -n "$(kokoro_sec '.inbound.uuid')" ]] || kokoro_die "missing inbound.uuid in secrets.json"
    [[ -n "$(kokoro_sec '.inbound.xhttp_path')" ]] || kokoro_die "missing inbound.xhttp_path in secrets.json"
    if [[ "$(kokoro_cfg '.inbound.vless_encryption.enabled // false')" == "true" ]]; then
        decryption="$(kokoro_sec '.inbound.vless_encryption.decryption')"
        encryption="$(kokoro_sec '.inbound.vless_encryption.encryption')"
        [[ -n "$decryption" && "$decryption" != "null" ]] || kokoro_die "missing VLESS decryption key"
        [[ -n "$encryption" && "$encryption" != "null" ]] || kokoro_die "missing VLESS encryption key"
    fi

    if [[ "$mode" == "reality" || "$mode" == "both" ]]; then
        [[ -n "$(kokoro_sec '.inbound.reality.private_key')" ]] || kokoro_die "missing reality private key"
        [[ -n "$(kokoro_sec '.inbound.reality.short_ids[0]')" ]] || kokoro_die "missing reality short_id"
    fi

    if [[ "$mode" == "tls" || "$mode" == "both" ]]; then
        cdn="$(kokoro_cfg '.inbound.tls.cdn_domain')"
        [[ -n "$cdn" && "$cdn" != "null" ]] || kokoro_die "inbound.tls.cdn_domain required for tls/both mode"
    fi

    if [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]]; then
        kokoro_preflight_hysteria "$cdn"
    fi

    if [[ "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
        kokoro_die "Tor is exit-only — enable on exit node after pair (kokoro-xray tor on)"
    fi

    if [[ "$(kokoro_cfg '.multinode.enabled')" == "true" ]]; then
        [[ -n "$(kokoro_sec '.multinode.edge_wg_privkey')" ]] || kokoro_die "missing edge WG private key"
        [[ -n "$(kokoro_cfg '.multinode.peer_exit_pubkey')" ]] || kokoro_die "missing multinode.peer_exit_pubkey"
        [[ -n "$(kokoro_cfg '.multinode.exit_ip')" ]] || kokoro_die "missing multinode.exit_ip"
    fi
}

kokoro_preflight_hysteria() {
    local cdn="${1:-}" domain email ports interval masquerade cert key item from to
    local -a items
    domain="$(kokoro_cfg '.inbound.hysteria.domain' | tr '[:upper:]' '[:lower:]')"
    email="$(kokoro_cfg '.inbound.hysteria.acme_email')"
    ports="$(kokoro_cfg '.inbound.hysteria.ports')"
    interval="$(kokoro_cfg '.inbound.hysteria.hop_interval')"
    masquerade="$(kokoro_cfg '.inbound.hysteria.masquerade' | tr '[:upper:]' '[:lower:]')"
    cert="$(kokoro_cfg '.paths.hysteria_cert')"
    key="$(kokoro_cfg '.paths.hysteria_key')"

    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
        kokoro_die "invalid Hysteria2 domain: $domain"
    [[ -n "$email" && "$email" != "null" ]] || kokoro_die "Hysteria2 ACME email required"
    [[ "$masquerade" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
        kokoro_die "invalid Hysteria2 masquerade domain: $masquerade"
    [[ "$domain" != "$masquerade" ]] || kokoro_die "Hysteria2 masquerade must be a different domain"
    [[ -z "$cdn" || "$cdn" == "null" || "$domain" != "${cdn,,}" ]] ||
        kokoro_die "Hysteria2 needs a DNS-only domain separate from the CDN domain"
    [[ "$ports" == *,* || "$ports" == *-* ]] || kokoro_die "Hysteria2 port hopping requires multiple UDP ports"

    IFS=',' read -ra items <<<"$ports"
    for item in "${items[@]}"; do
        kokoro_firewall_parse_allow "${item}/udp" >/dev/null
    done

    [[ "$interval" =~ ^[0-9]+(-[0-9]+)?$ ]] || kokoro_die "invalid Hysteria2 hop interval: $interval"
    from="${interval%%-*}"
    to="${interval##*-}"
    [[ "$from" -ge 5 && "$to" -ge "$from" ]] || kokoro_die "Hysteria2 hop interval must be >=5 seconds"

    [[ -f "$cert" ]] || kokoro_die "Hysteria2 certificate missing: $cert"
    [[ -f "$key" ]] || kokoro_die "Hysteria2 private key missing: $key"
    [[ -n "$(kokoro_sec '.inbound.hysteria.auth')" ]] || kokoro_die "missing Hysteria2 auth secret"
    [[ -n "$(kokoro_sec '.inbound.hysteria.obfs_password')" ]] || kokoro_die "missing Hysteria2 obfs secret"
}

kokoro_preflight_exit() {
    [[ -n "$(kokoro_sec '.multinode.exit_wg_privkey')" ]] || kokoro_die "missing exit WG private key"
    [[ -n "$(kokoro_cfg '.multinode.peer_edge_pubkey')" ]] || kokoro_die "missing multinode.peer_edge_pubkey (run pair)"

    if [[ "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
        [[ -n "$(kokoro_cfg '.multinode.peer_edge_pubkey')" ]] || kokoro_die "pair edge before enabling Tor"
    fi
}
