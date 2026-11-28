#!/usr/bin/env bash
# kokoro-xray — last-good config snapshots

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_snapshot_save() {
    local xray_cfg caddyfile
    kokoro_validate_service_paths || return 1
    xray_cfg="$(kokoro_cfg '.paths.xray_config')" || return 1
    caddyfile="$(kokoro_cfg '.paths.caddyfile')" || return 1
    install -d -m 700 "${KOKORO_LAST_GOOD}" || return 1
    if [[ -f "$xray_cfg" ]]; then
        kokoro_write_private "${KOKORO_LAST_GOOD}/config.json" cat -- "$xray_cfg" || return 1
    fi
    if [[ -f "$caddyfile" ]]; then
        kokoro_write_private "${KOKORO_LAST_GOOD}/Caddyfile" cat -- "$caddyfile" || return 1
    fi
}

kokoro_snapshot_restore() {
    local xray_cfg caddyfile
    kokoro_validate_service_paths || return 1
    xray_cfg="$(kokoro_cfg '.paths.xray_config')" || return 1
    caddyfile="$(kokoro_cfg '.paths.caddyfile')" || return 1
    if [[ -f "${KOKORO_LAST_GOOD}/config.json" ]]; then
        install -d "$(dirname "$xray_cfg")" || return 1
        kokoro_write_private "$xray_cfg" cat -- "${KOKORO_LAST_GOOD}/config.json" || return 1
    fi
    if [[ -f "${KOKORO_LAST_GOOD}/Caddyfile" ]]; then
        kokoro_write_private "$caddyfile" cat -- "${KOKORO_LAST_GOOD}/Caddyfile" || return 1
    fi
}

kokoro_snapshot_exists() {
    kokoro_validate_service_paths || return 1
    [[ -f "${KOKORO_LAST_GOOD}/config.json" ]]
}
