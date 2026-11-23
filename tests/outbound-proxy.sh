#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
if [[ "${1:-}" == --manage ]]; then
    source "$ROOT/lib/onboard.sh"
    kokoro_need_root() { :; }
    kokoro_state_refresh
    kokoro_manage_outbound_proxy
    exit
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" KOKORO_ROOT="$ROOT"
source "$ROOT/lib/onboard.sh"
kokoro_ensure_state
kokoro_cfg_set_str '.role' edge
kokoro_cfg_set_str '.inbound.transport' xhttp
kokoro_cfg_set_str '.inbound.mode' tls
kokoro_cfg_set_str '.inbound.tls.cdn_domain' tls.example.com
kokoro_sec_set_str '.inbound.uuid' test-uuid
cp "$KOKORO_CONFIG" "$TMP/config.before"
cp "$KOKORO_SECRETS" "$TMP/secrets.before"

manage_proxy() {
    printf '%s\n' "$@" | script -qec 'bash "$KOKORO_ROOT/tests/outbound-proxy.sh" --manage' \
        /dev/null >"$TMP/menu.log"
}

manage_proxy y socks5 proxy.example.com 1080 'example.com,Example.com' alice 'dummy-pass'
grep -q 'outbound proxy saved' "$TMP/menu.log"
jq -e '.outbound_proxy == {protocol:"socks",address:"proxy.example.com",port:1080,
    domains:["example.com"],user:"alice",pass:"dummy-pass"}' "$KOKORO_SECRETS" >/dev/null

manage_proxy edit '' '' '' video.example.com '' ''
grep -q 'outbound proxy saved' "$TMP/menu.log"
if grep -q 'dummy-pass' "$TMP/menu.log"; then
    echo 'saved password displayed during edit' >&2
    exit 1
fi
jq -e '.outbound_proxy | .domains == ["video.example.com"] and .pass == "dummy-pass"
    and .protocol == "socks" and .address == "proxy.example.com" and .port == 1080 and .user == "alice"' \
    "$KOKORO_SECRETS" >/dev/null
[[ "$(stat -c %a "$KOKORO_SECRETS")" == 600 ]]

cp "$KOKORO_SECRETS" "$TMP/secrets.edited"
manage_proxy keep
grep -q 'outbound proxy unchanged' "$TMP/menu.log"
if manage_proxy edit http '' 0; then
    echo 'invalid proxy port accepted' >&2
    exit 1
fi
cmp "$KOKORO_SECRETS" "$TMP/secrets.edited"

manage_proxy remove
grep -q 'outbound proxy saved' "$TMP/menu.log"
jq -e '.outbound_proxy == null' "$KOKORO_SECRETS" >/dev/null
cmp "$KOKORO_CONFIG" "$TMP/config.before"
diff -u <(jq 'del(.outbound_proxy)' "$TMP/secrets.before") \
    <(jq 'del(.outbound_proxy)' "$KOKORO_SECRETS")
echo 'outbound-proxy-test OK'
