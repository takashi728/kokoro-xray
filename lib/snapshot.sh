#!/usr/bin/env bash
# kokoro-xray — last-good config snapshots

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_snapshot_save() {
    local xray_cfg caddyfile
    kokoro_validate_service_paths
    xray_cfg="$(kokoro_cfg '.paths.xray_config')"
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    install -d -m 700 "${KOKORO_LAST_GOOD}"
    [[ -f "$xray_cfg" ]] && cp "$xray_cfg" "${KOKORO_LAST_GOOD}/config.json"
    [[ -f "$caddyfile" ]] && cp "$caddyfile" "${KOKORO_LAST_GOOD}/Caddyfile"
}

kokoro_snapshot_restore() {
    local xray_cfg caddyfile
    kokoro_validate_service_paths
    xray_cfg="$(kokoro_cfg '.paths.xray_config')"
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    if [[ -f "${KOKORO_LAST_GOOD}/config.json" ]]; then
        install -d "$(dirname "$xray_cfg")"
        cp "${KOKORO_LAST_GOOD}/config.json" "$xray_cfg"
        chmod 600 "$xray_cfg"
    fi
    if [[ -f "${KOKORO_LAST_GOOD}/Caddyfile" ]]; then
        cp "${KOKORO_LAST_GOOD}/Caddyfile" "$caddyfile"
    fi
}

kokoro_snapshot_exists() {
    kokoro_validate_service_paths
    [[ -f "${KOKORO_LAST_GOOD}/config.json" ]]
}
