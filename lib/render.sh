#!/usr/bin/env bash
# kokoro-xray — render dispatcher (jq only, no sed)

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_render_xray() {
    local out
    out="$(kokoro_cfg '.paths.xray_config')"
    install -d "$(dirname "$out")"
    jq -n -f "${KOKORO_ROOT}/lib/render.jq" \
        --slurpfile cfg "${KOKORO_CONFIG}" \
        --slurpfile sec "${KOKORO_SECRETS}" \
        >"${out}.tmp"
    mv "${out}.tmp" "$out"
    chmod 600 "$out"
}

kokoro_render_caddy() {
    local out
    kokoro_caddy_required || return 0
    out="$(kokoro_cfg '.paths.caddyfile')"
    install -d "$(dirname "$out")"
    jq -n -r -f "${KOKORO_ROOT}/lib/caddy.jq" \
        --slurpfile cfg "${KOKORO_CONFIG}" \
        --slurpfile sec "${KOKORO_SECRETS}" \
        >"${out}.tmp"
    mv "${out}.tmp" "$out"
}

kokoro_render() {
    local role
    role="$(kokoro_cfg '.role')"
    case "$role" in
        edge)
            kokoro_render_xray
            kokoro_render_caddy
            ;;
        exit)
            kokoro_render_xray
            ;;
        *)
            kokoro_die "cannot render: role not set"
            ;;
    esac
}

# Legacy aliases for roles still sourcing this file
kokoro_build_edge_xray() { kokoro_render_xray; }
kokoro_build_exit_xray() { kokoro_render_xray; }
kokoro_build_edge_caddy() { kokoro_render_caddy; }
