#!/usr/bin/env bash
# kokoro-xray — validate intent before render

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/firewall.sh"
source "${KOKORO_ROOT}/lib/fallback.sh"
source "${KOKORO_ROOT}/lib/cloudflare.sh"

kokoro_preflight() {
    local role mode
    role="$(kokoro_cfg '.role')"
    mode="$(kokoro_cfg '.inbound.mode')"

    kokoro_preflight_paths
    kokoro_cf_validate || kokoro_die "$(kokoro_cf_text cf_invalid)"
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

kokoro_preflight_paths() { kokoro_validate_service_paths; }

kokoro_preflight_edge() {
    local mode="$1" cdn="" decryption encryption transport
    transport="$(kokoro_cfg '.inbound.transport // "xhttp"')"
    case "$transport" in
        raw|xhttp) ;;
        *) kokoro_die "invalid inbound.transport: $transport (raw or xhttp)" ;;
    esac
    case "$mode" in
        reality|tls|both|argo) ;;
        *) kokoro_die "invalid inbound.mode: $mode" ;;
    esac

    jq -nr -f "${KOKORO_ROOT}/lib/caddy.jq" \
        --slurpfile cfg "$KOKORO_CONFIG" --slurpfile sec "$KOKORO_SECRETS" >/dev/null ||
        kokoro_die "invalid Caddy configuration inputs"
    [[ -n "$(kokoro_sec '.inbound.uuid')" ]] || kokoro_die "missing inbound.uuid in secrets.json"
    [[ "$transport" == raw || -n "$(kokoro_sec '.inbound.xhttp_path')" ]] || kokoro_die "missing inbound.xhttp_path in secrets.json"
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
        cdn="$(kokoro_tls_domain)"
        cdn="${cdn,,}"
        [[ -n "$cdn" && "$cdn" != "null" ]] || kokoro_die "TLS domain required (inbound.tls.domain for RAW; inbound.tls.cdn_domain for XHTTP)"
        if [[ "$transport" == raw ]]; then
            [[ "$cdn" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
                kokoro_die "RAW TLS requires a valid direct domain"
            [[ "$(kokoro_cfg '.caddy.use_l4')" == true ]] || kokoro_die "RAW TLS requires caddy.use_l4=true"
            if [[ "$mode" == both ]] && kokoro_cfg '.inbound.reality.server_names' | jq -e --arg domain "$cdn" 'map(ascii_downcase) | index($domain) != null' >/dev/null; then
                kokoro_die "RAW TLS domain must differ from the REALITY SNI in both mode"
            fi
            kokoro_require_hysteria_file '.paths.tls_cert' '.crt'
            kokoro_require_hysteria_file '.paths.tls_key' '.key'
            kokoro_fallback_preflight
        fi
    fi

    if [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]]; then
        kokoro_preflight_hysteria "$cdn"
        if [[ "$mode" == "reality" && "$(kokoro_cfg '.caddy.use_l4')" != "true" ]]; then
            kokoro_die "Hysteria2 in reality mode needs caddy.use_l4=true for the TCP pivot"
        fi
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
    local cdn="${1:-}" domain email ports interval masquerade item from to
    local -a items
    domain="$(kokoro_cfg '.inbound.hysteria.domain' | tr '[:upper:]' '[:lower:]')"
    email="$(kokoro_cfg '.inbound.hysteria.acme_email')"
    ports="$(kokoro_cfg '.inbound.hysteria.ports')"
    interval="$(kokoro_cfg '.inbound.hysteria.hop_interval')"
    masquerade="$(kokoro_cfg '.inbound.hysteria.masquerade' | tr '[:upper:]' '[:lower:]')"

    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
        kokoro_die "invalid Hysteria2 domain: $domain"
    [[ -n "$email" && "$email" != "null" ]] || kokoro_die "Hysteria2 ACME email required"
    [[ "$masquerade" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
        kokoro_die "invalid Hysteria2 masquerade domain: $masquerade"
    [[ "$domain" != "$masquerade" ]] || kokoro_die "Hysteria2 masquerade must be a different domain"
    [[ "$ports" == *,* || "$ports" == *-* ]] || kokoro_die "Hysteria2 port hopping requires multiple UDP ports"

    IFS=',' read -ra items <<<"$ports"
    for item in "${items[@]}"; do
        kokoro_firewall_parse_allow "${item}/udp" >/dev/null
    done

    [[ "$interval" =~ ^[0-9]+(-[0-9]+)?$ ]] || kokoro_die "invalid Hysteria2 hop interval: $interval"
    from="${interval%%-*}"
    to="${interval##*-}"
    [[ "$from" -ge 5 && "$to" -ge "$from" ]] || kokoro_die "Hysteria2 hop interval must be >=5 seconds"

    kokoro_require_hysteria_file '.paths.hysteria_cert' '.crt'
    kokoro_require_hysteria_file '.paths.hysteria_key' '.key'
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
