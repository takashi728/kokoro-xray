#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP"
mkdir -p "${HOME}/.kokoro-xray"
cp "${ROOT}/config.defaults.json" "${HOME}/.kokoro-xray/config.json"
cp "${ROOT}/secrets.defaults.json" "${HOME}/.kokoro-xray/secrets.json"

source "${ROOT}/lib/common.sh"
kokoro_ensure_state

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

echo "state-test OK"
