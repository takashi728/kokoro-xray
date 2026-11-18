#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" KOKORO_ROOT="$ROOT"
source "$ROOT/lib/render.sh"
kokoro_validate_service_paths() { :; }
kokoro_caddy_required() { return 0; }
kokoro_cfg() {
    case "$1" in
        .role) printf 'edge\n' ;;
        .paths.xray_config) printf '%s/xray.json\n' "$TMP" ;;
        .paths.caddyfile) printf '%s/Caddyfile\n' "$TMP" ;;
        *) return 1 ;;
    esac
}
printf 'existing-xray\n' >"$TMP/xray.json"
printf 'existing-caddy\n' >"$TMP/Caddyfile"
jq() { printf 'partial invalid output\n'; return 3; }
if kokoro_render; then
    echo 'dispatcher swallowed render failure' >&2
    exit 1
fi
if kokoro_render_caddy; then
    echo 'Caddy renderer swallowed jq failure' >&2
    exit 1
fi
[[ "$(cat "$TMP/xray.json")" == existing-xray ]]
[[ "$(cat "$TMP/Caddyfile")" == existing-caddy ]]
[[ "$(find "$TMP" -type f | wc -l)" -eq 2 ]]
jq() {
    local staged
    staged="$(find "$TMP" -name 'xray.json.*' -print -quit)"
    [[ "$(stat -c '%a' "$staged")" == 600 ]] || return 1
    printf '{"rendered":true}\n'
}
kokoro_render_xray
[[ "$(cat "$TMP/xray.json")" == '{"rendered":true}' ]]
[[ "$(stat -c '%a' "$TMP/xray.json")" == 600 ]]
echo 'render-failure-test OK'
