#!/usr/bin/env bash
set -euo pipefail
umask 0022

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP"
mkdir -p "${HOME}/.kokoro-xray"
cp "${ROOT}/config.defaults.json" "${HOME}/.kokoro-xray/config.json"
cp "${ROOT}/secrets.defaults.json" "${HOME}/.kokoro-xray/secrets.json"

source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/render.sh"
source "${ROOT}/lib/snapshot.sh"
kokoro_ensure_state

mv() {
    local source="${@: -2:1}" destination="${@: -1}"
    [[ "$(dirname -- "$source")" == "$(dirname -- "$destination")" ]] || return 1
    [[ "$(stat -c '%a' -- "$source")" == 600 ]] || return 1
    command mv "$@"
}

# scalar reads resolve from the flattened state
[[ "$(kokoro_cfg '.inbound.mode')" == "both" ]]
[[ "$(kokoro_cfg '.inbound.vless_encryption.enabled')" == "true" ]]

# setters persist to disk and refresh the in-memory state
kokoro_cfg_set_str '.inbound.mode' 'reality'
[[ "$(kokoro_cfg '.inbound.mode')" == "reality" ]]
kokoro_cfg_set '.firewall.ssh_port' '2222'
[[ "$(kokoro_cfg '.firewall.ssh_port')" == "2222" ]]
kokoro_sec_set_str '.static_proxy.username' 'user1'
[[ "$(kokoro_sec '.static_proxy.username')" == "user1" ]]

# arrays and missing paths fall back to jq with preserved semantics
kokoro_cfg '.inbound.reality.server_names' | grep -q 'www.cloudflare.com'
[[ "$(kokoro_cfg '.no.such.path')" == "null" ]]
[[ "$(kokoro_cfg '.inbound.vless_encryption.enabled // false')" == "true" ]]

# file actually written
[[ "$(jq -r '.inbound.mode' "${HOME}/.kokoro-xray/config.json")" == "reality" ]]
[[ "$(jq -r '.static_proxy.username' "${HOME}/.kokoro-xray/secrets.json")" == "user1" ]]
[[ "$(stat -c '%a' "${HOME}/.kokoro-xray/config.json")" == "644" ]]
[[ "$(stat -c '%a' "${HOME}/.kokoro-xray/secrets.json")" == "600" ]]

xray="$TMP/service/xray.json"
caddy="$TMP/service/Caddyfile"
kokoro_cfg_set_str '.paths.xray_config' "$xray"
kokoro_cfg_set_str '.paths.caddyfile' "$caddy"
kokoro_cfg_set_str '.role' exit
kokoro_validate_service_paths() {
    [[ "$(kokoro_cfg '.paths.xray_config')" == "$xray" && "$(kokoro_cfg '.paths.caddyfile')" == "$caddy" ]]
}
kokoro_render_xray
[[ "$(stat -c '%a' "$xray")" == 600 ]]
cp "$xray" "$TMP/expected"
chmod 644 "$xray"
kokoro_snapshot_save
[[ "$(stat -c '%a' "$KOKORO_LAST_GOOD/config.json")" == 600 ]]
cmp "$TMP/expected" "$KOKORO_LAST_GOOD/config.json"
printf 'old config\n' >"$xray"
ln "$xray" "$TMP/old-inode"
kokoro_snapshot_restore
[[ "$(stat -c '%a' "$xray")" == 600 && "$(<"$TMP/old-inode")" == 'old config' ]]
cmp "$TMP/expected" "$xray"

expect_failure() {
    if "$@"; then
        echo "unexpected success: $1" >&2
        exit 1
    fi
}

cp "$KOKORO_SECRETS" "$TMP/original-secrets"
expect_failure kokoro_sec_set '.json' 'error("test failure")' 2>/dev/null
(
    chmod() { return 1; }
    expect_failure kokoro_sec_set_str '.json' discarded
)
(
    mv() { return 1; }
    expect_failure kokoro_sec_set_str '.json' discarded
    expect_failure kokoro_render_xray
    expect_failure kokoro_snapshot_restore
)
(
    cat() { printf 'partial output'; return 1; }
    expect_failure kokoro_snapshot_save
)
cmp "$TMP/original-secrets" "$KOKORO_SECRETS"
cmp "$TMP/expected" "$KOKORO_LAST_GOOD/config.json"
cmp "$TMP/expected" "$xray"
[[ "$(kokoro_sec '.static_proxy.username')" == user1 ]]
for target in "$KOKORO_CONFIG" "$KOKORO_SECRETS" "$KOKORO_LAST_GOOD/config.json" "$xray"; do
    if compgen -G "${target}.*" >/dev/null; then
        echo "staged file left behind for $target" >&2
        exit 1
    fi
done

echo "state-test OK"
