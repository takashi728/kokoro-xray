#!/usr/bin/env bash
# kokoro-xray — key and secret generation

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_rand_path() {
    local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    local out="/" i c
    for i in $(seq 1 24); do
        c="${chars:RANDOM%${#chars}:1}"
        out+="$c"
    done
    printf '%s\n' "$out"
}

kokoro_rand_short_id() { openssl rand -hex 4; }

kokoro_gen_uuid() {
    local xray_bin
    xray_bin="$(kokoro_cfg '.paths.xray_bin')"
    if [[ -x "$xray_bin" ]]; then
        "$xray_bin" uuid
        return
    fi
    command -v uuidgen >/dev/null 2>&1 && uuidgen | tr '[:upper:]' '[:lower:]' || kokoro_die "cannot generate uuid"
}

kokoro_gen_reality_keys() {
    local xray_bin out priv pub
    xray_bin="$(kokoro_cfg '.paths.xray_bin')"
    [[ -x "$xray_bin" ]] || kokoro_die "xray not installed"
    out="$("$xray_bin" x25519)"
    priv="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private.*key|privatekey/ {print $2; exit}')"
    pub="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /public.*key|publickey|password/ {print $2; exit}')"
    priv="${priv%%[[:space:]]*}"
    pub="${pub%%[[:space:]]*}"
    if [[ -z "$priv" || -z "$pub" ]]; then
        printf '%s\n' "$out" >&2
        kokoro_die "failed to parse xray x25519 output"
    fi
    kokoro_sec_set_str '.inbound.reality.private_key' "$priv"
    kokoro_sec_set_str '.inbound.reality.public_key' "$pub"
}

kokoro_gen_vless_encryption_keys() {
    local xray_bin out decryption encryption
    xray_bin="$(kokoro_cfg '.paths.xray_bin')"
    [[ -x "$xray_bin" ]] || kokoro_die "xray not installed"
    out="$("$xray_bin" vlessenc)"
    decryption="$(printf '%s\n' "$out" | awk -F'"' '$2 == "decryption" {print $4; exit}')"
    encryption="$(printf '%s\n' "$out" | awk -F'"' '$2 == "encryption" {print $4; exit}')"
    if [[ ! "$decryption" =~ ^mlkem768x25519plus\.native\.600s\.[A-Za-z0-9_-]{43}$ ||
        ! "$encryption" =~ ^mlkem768x25519plus\.native\.0rtt\.[A-Za-z0-9_-]{43}$ ]]; then
        printf '%s\n' "$out" >&2
        kokoro_die "failed to parse xray vlessenc output"
    fi
    kokoro_sec_set_str '.inbound.vless_encryption.decryption' "$decryption"
    kokoro_sec_set_str '.inbound.vless_encryption.encryption' "$encryption"
}

kokoro_ensure_vless_encryption_keys() {
    local decryption encryption
    [[ "$(kokoro_cfg '.role')" == "edge" ]] || return 0
    [[ "$(kokoro_cfg '.inbound.vless_encryption.enabled // false')" == "true" ]] || return 0
    decryption="$(kokoro_sec '.inbound.vless_encryption.decryption')"
    encryption="$(kokoro_sec '.inbound.vless_encryption.encryption')"
    if [[ -z "$decryption" || "$decryption" == "null" ||
        -z "$encryption" || "$encryption" == "null" ]]; then
        kokoro_gen_vless_encryption_keys
        kokoro_log "generated VLESS Encryption keys"
    fi
}

kokoro_gen_edge_wg_keys() {
    local priv pub
    priv="$(wg genkey)"
    pub="$(printf '%s' "$priv" | wg pubkey)"
    kokoro_sec_set_str '.multinode.edge_wg_privkey' "$priv"
    kokoro_sec_set_str '.multinode.edge_wg_pubkey' "$pub"
}

kokoro_gen_exit_wg_keys() {
    local priv pub
    priv="$(wg genkey)"
    pub="$(printf '%s' "$priv" | wg pubkey)"
    kokoro_sec_set_str '.multinode.exit_wg_privkey' "$priv"
    kokoro_sec_set_str '.multinode.exit_wg_pubkey' "$pub"
}

kokoro_secrets_exist() {
    local role
    role="$(kokoro_cfg '.role')"
    case "$role" in
        edge)
            [[ -n "$(kokoro_sec '.inbound.uuid')" && -n "$(kokoro_sec '.inbound.reality.private_key')" ]]
            ;;
        exit)
            [[ -n "$(kokoro_sec '.multinode.exit_wg_privkey')" ]]
            ;;
        *)
            false
            ;;
    esac
}

kokoro_gen_edge_secrets() {
    local uuid path sid
    uuid="$(kokoro_gen_uuid)"
    path="$(kokoro_rand_path)"
    sid="$(kokoro_rand_short_id)"
    kokoro_sec_set_str '.inbound.uuid' "$uuid"
    kokoro_sec_set_str '.inbound.xhttp_path' "$path"
    kokoro_sec_set '.inbound.reality.short_ids' "[\"${sid}\"]"
    kokoro_gen_reality_keys
    kokoro_ensure_vless_encryption_keys
    kokoro_gen_edge_wg_keys
}

kokoro_gen_exit_secrets() {
    kokoro_gen_exit_wg_keys
}

kokoro_gen_secrets() {
    local role
    role="$(kokoro_cfg '.role')"
    case "$role" in
        edge) kokoro_gen_edge_secrets ;;
        exit) kokoro_gen_exit_secrets ;;
        *) kokoro_die "role not set for secret generation" ;;
    esac
}
