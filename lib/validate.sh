#!/usr/bin/env bash
# kokoro-xray — config validation

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_validate_geo() {
    local geo_dir
    geo_dir="$(kokoro_cfg '.paths.geo_dir')"
    if [[ ! -f "${geo_dir}/geoip.dat" || ! -f "${geo_dir}/geosite.dat" ]]; then
        kokoro_warn "missing geoip.dat/geosite.dat in ${geo_dir}"
        return 1
    fi
    return 0
}

kokoro_validate() {
    local xray_bin cfg caddyfile role
    xray_bin="$(kokoro_cfg '.paths.xray_bin')"
    cfg="$(kokoro_cfg '.paths.xray_config')"
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    role="$(kokoro_cfg '.role')"

    [[ -f "$cfg" ]] || { kokoro_warn "missing xray config: $cfg"; return 1; }
    [[ -x "$xray_bin" ]] || { kokoro_warn "xray binary not found: $xray_bin"; return 1; }

    kokoro_validate_geo || return 1
    "$xray_bin" run -test -config "$cfg" || { kokoro_warn "xray config test failed"; return 1; }

    if [[ "$role" == "edge" ]] && kokoro_caddy_required && [[ -f "$caddyfile" ]]; then
        local caddy_bin
        caddy_bin="$(kokoro_cfg '.paths.caddy_bin')"
        if [[ -x "$caddy_bin" ]]; then
            "$caddy_bin" validate --config "$caddyfile" || { kokoro_warn "caddy validate failed"; return 1; }
        else
            kokoro_warn "caddy binary not found — skipping caddy validate"
        fi
    fi

    kokoro_log "validation passed"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    export KOKORO_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
    kokoro_ensure_state
    kokoro_validate || exit 1
fi
