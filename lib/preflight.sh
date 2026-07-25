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

    if [[ "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
        kokoro_die "Tor is exit-only — enable on exit node after pair (kokoro-xray tor on)"
    fi

    if [[ "$(kokoro_cfg '.multinode.enabled')" == "true" ]]; then
        [[ -n "$(kokoro_sec '.multinode.edge_wg_privkey')" ]] || kokoro_die "missing edge WG private key"
        [[ -n "$(kokoro_cfg '.multinode.peer_exit_pubkey')" ]] || kokoro_die "missing multinode.peer_exit_pubkey"
        [[ -n "$(kokoro_cfg '.multinode.exit_ip')" ]] || kokoro_die "missing multinode.exit_ip"
    fi
}

kokoro_preflight_exit() {
    [[ -n "$(kokoro_sec '.multinode.exit_wg_privkey')" ]] || kokoro_die "missing exit WG private key"
    [[ -n "$(kokoro_cfg '.multinode.peer_edge_pubkey')" ]] || kokoro_die "missing multinode.peer_edge_pubkey (run pair)"

    if [[ "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
        [[ -n "$(kokoro_cfg '.multinode.peer_edge_pubkey')" ]] || kokoro_die "pair edge before enabling Tor"
    fi
}
