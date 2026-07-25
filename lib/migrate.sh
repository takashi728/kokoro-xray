#!/usr/bin/env bash
# kokoro-xray — config schema migration

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_migrate() {
    local ver tmp
    kokoro_migrate_merge_defaults

    ver="$(kokoro_cfg '.version // "0.1.0"')"

    if [[ "$ver" == "0.1.0" ]]; then
        kokoro_migrate_v010_to_v020
        kokoro_cfg_set_str '.version' '0.2.0'
        kokoro_log "migrated config 0.1.0 → 0.2.0"
    fi

    ver="$(kokoro_cfg '.version')"
    if [[ "$ver" == "0.2.0" ]]; then
        kokoro_cfg_set '.inbound.vless_encryption.enabled' 'false'
        kokoro_cfg_set_str '.version' '0.3.0'
        kokoro_sec_set_str '.version' '0.3.0'
        kokoro_log "migrated config 0.2.0 → 0.3.0 (VLESS Encryption disabled)"
    fi

    ver="$(kokoro_cfg '.version')"
    if [[ "$ver" == "0.3.0" ]]; then
        kokoro_cfg_set '.inbound.hysteria.enabled' 'false'
        if [[ "$(kokoro_cfg '.caddy.version')" == "2.9.1" ]]; then
            kokoro_cfg_set_str '.caddy.version' '2.11.3'
        fi
        kokoro_cfg_set_str '.version' '0.4.0'
        kokoro_sec_set_str '.version' '0.4.0'
        kokoro_log "migrated config 0.3.0 → 0.4.0 (Hysteria2 disabled)"
    fi

    if ! jq -e '.firewall' "${KOKORO_CONFIG}" >/dev/null 2>&1; then
        tmp="$(mktemp)"
        jq '.firewall = {"enabled": true, "ssh_port": 0, "extra_allow": []}' \
            "${KOKORO_CONFIG}" >"$tmp"
        mv "$tmp" "${KOKORO_CONFIG}"
    fi
}

kokoro_migrate_merge_defaults() {
    local tmp

    tmp="$(mktemp)"
    jq -s '
      .[0] as $d | (.[0] * .[1])
      | .paths.xray_config = (if (.paths.xray_config // "") == "" then $d.paths.xray_config else .paths.xray_config end)
      | .paths.caddyfile = (if (.paths.caddyfile // "") == "" then $d.paths.caddyfile else .paths.caddyfile end)
      | .paths.xray_bin = (if (.paths.xray_bin // "") == "" then $d.paths.xray_bin else .paths.xray_bin end)
      | .paths.caddy_bin = (if (.paths.caddy_bin // "") == "" then $d.paths.caddy_bin else .paths.caddy_bin end)
      | .paths.geo_dir = (if (.paths.geo_dir // "") == "" then $d.paths.geo_dir else .paths.geo_dir end)
      | .caddy.version = (if (.caddy.version // "") == "" then $d.caddy.version else .caddy.version end)
      | .caddy.use_l4 = (.caddy.use_l4 // $d.caddy.use_l4)
      | .firewall.enabled = (.firewall.enabled // $d.firewall.enabled)
      | .firewall.ssh_port = (.firewall.ssh_port // $d.firewall.ssh_port)
      | .firewall.extra_allow = (.firewall.extra_allow // $d.firewall.extra_allow)
    ' \
        "${KOKORO_ROOT}/config.defaults.json" \
        "${KOKORO_CONFIG}" >"$tmp"
    mv "$tmp" "${KOKORO_CONFIG}"
    chmod 644 "${KOKORO_CONFIG}"

    tmp="$(mktemp)"
    jq -s '.[0] * .[1]' \
        "${KOKORO_ROOT}/secrets.defaults.json" \
        "${KOKORO_SECRETS}" >"$tmp"
    mv "$tmp" "${KOKORO_SECRETS}"
    chmod 600 "${KOKORO_SECRETS}"
}

kokoro_migrate_v010_to_v020() {
    local tmp
    tmp="$(mktemp)"

    # Move secrets from config.json → secrets.json
    if jq -e '.inbound.uuid // empty' "${KOKORO_CONFIG}" >/dev/null 2>&1; then
        local uuid path priv pub sid edge_priv edge_pub exit_pub
        uuid="$(jq -r '.inbound.uuid // ""' "${KOKORO_CONFIG}")"
        path="$(jq -r '.inbound.xhttp_path // ""' "${KOKORO_CONFIG}")"
        priv="$(jq -r '.inbound.reality.private_key // ""' "${KOKORO_CONFIG}")"
        pub="$(jq -r '.inbound.reality.public_key // ""' "${KOKORO_CONFIG}")"
        sid="$(jq -r '.inbound.reality.short_ids[0] // ""' "${KOKORO_CONFIG}")"
        edge_priv="$(jq -r '.multinode.local_privkey // ""' "${KOKORO_CONFIG}")"
        edge_pub="$(jq -r '.multinode.local_pubkey // ""' "${KOKORO_CONFIG}")"
        exit_pub="$(jq -r '.multinode.exit_pubkey // ""' "${KOKORO_CONFIG}")"

        jq \
            --arg uuid "$uuid" --arg path "$path" \
            --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
            --arg epriv "$edge_priv" --arg epub "$edge_pub" \
            '.inbound.uuid = $uuid
             | .inbound.xhttp_path = $path
             | .inbound.reality.private_key = $priv
             | .inbound.reality.public_key = $pub
             | .inbound.reality.short_ids = [$sid]
             | .multinode.edge_wg_privkey = $epriv
             | .multinode.edge_wg_pubkey = $epub' \
            "${KOKORO_SECRETS}" >"$tmp"
        mv "$tmp" "${KOKORO_SECRETS}"
        chmod 600 "${KOKORO_SECRETS}"

        if [[ -n "$exit_pub" ]]; then
            kokoro_cfg_set_str '.multinode.peer_exit_pubkey' "$exit_pub"
        fi

        jq 'del(.inbound.uuid, .inbound.xhttp_path)
            | .inbound.reality |= del(.private_key, .public_key, .short_ids)
            | .multinode |= del(.local_privkey, .local_pubkey, .exit_pubkey)
            | .multinode.peer_exit_pubkey //= ""
            | .multinode.peer_edge_pubkey //= ""
            | .version = "0.2.0"
            | .caddy = {"version":"2.9.1","use_l4":true}
            | .paths.caddy_bin = "/usr/local/bin/caddy"
            | .paths.geo_dir = "/usr/local/share/xray"
            | .inbound.tls.acme_email //= ""' \
            "${KOKORO_CONFIG}" >"$tmp"
        mv "$tmp" "${KOKORO_CONFIG}"
    fi
}
