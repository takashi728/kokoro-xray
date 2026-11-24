#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp" KOKORO_ROOT="$ROOT" KOKORO_PUBLIC_ADDRESS=203.0.113.3
source "$ROOT/lib/common.sh"
kokoro_ensure_state
kokoro_cfg_set_str '.role' edge
kokoro_cfg_set_str '.inbound.tls.cdn_domain' cdn.example.com
cp "$ROOT/.github/fixtures/edge-secrets.json" "$KOKORO_SECRETS"
chmod 600 "$KOKORO_SECRETS"

cli() { bash "$ROOT/kokoro-xray.sh" "$@"; }
profile() { cli link --json xhttp-split "$@"; }
fails() {
    if ("$@") >"$tmp/rejected" 2>"$tmp/error"; then
        echo "unexpected success: $*" >&2
        exit 1
    fi
    [[ ! -s "$tmp/rejected" ]]
}
render() {
    jq -n -f "$ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" \
        --slurpfile sec "$KOKORO_SECRETS"
}

render | jq -e '.inbounds[0].streamSettings.network == "xhttp"' >/dev/null
fails profile cdn-h2 reality=2001:db8::42
fails profile cdn-h2=
fails profile reality
fails profile cdn-h3=999.0.0.1
fails profile reality=192.0.002.42
fails profile reality=:2001::42
fails profile cdn-h2 cdn-h2 cdn-h2

profile cdn-h2 cdn-h3=203.0.113.5 >"$tmp/cdn.json"
profile cdn-h3 >"$tmp/h3.json"
profile reality=2001:db8::42 >"$tmp/v6.json"
jq -e '
    .outbounds[0] | .settings.vnext[0].address == "cdn.example.com"
    and (.streamSettings | .tlsSettings.alpn == ["h2"] and
      (.xhttpSettings.downloadSettings |
        .address == "203.0.113.5" and .port == 443 and .network == "xhttp"
        and .tlsSettings.alpn == ["h3"] and .tlsSettings.serverName == "cdn.example.com"
        and .xhttpSettings.host == "cdn.example.com"))
' "$tmp/cdn.json" >/dev/null
jq -e '.outbounds[0].streamSettings | .tlsSettings.alpn == ["h3"]
    and (.xhttpSettings | has("downloadSettings") | not)' "$tmp/h3.json" >/dev/null
jq -e '.outbounds[0] | .settings.vnext[0].address == "2001:db8::42"
    and (.streamSettings.xhttpSettings | has("downloadSettings") | not)' "$tmp/v6.json" >/dev/null

kokoro_cfg_set_str '.inbound.tls.split_domain' split.example.com
kokoro_xhttp_split_domain_check split.example.com
fails kokoro_xhttp_split_domain_check cdn.example.com
fails kokoro_xhttp_split_domain_check www.cloudflare.com
fails profile direct-h2
profile cdn-h3 direct-h2=2001:db8::42 >"$tmp/cdn-direct.json"
jq -e '
    .outbounds[0] | .settings.vnext[0].address == "split.example.com"
    and (.streamSettings | .tlsSettings.serverName == "split.example.com"
      and .tlsSettings.alpn == ["h3"]
      and (.xhttpSettings.downloadSettings |
        .address == "2001:db8::42" and .tlsSettings.serverName == "cdn.example.com"
        and .tlsSettings.alpn == ["h2"] and .xhttpSettings.host == "cdn.example.com"))
' "$tmp/cdn-direct.json" >/dev/null
cli link --json tls | jq -e '.outbounds[0].settings.vnext[0].address == "cdn.example.com"' >/dev/null
jq -nr -f "$ROOT/lib/caddy.jq" --slurpfile cfg "$KOKORO_CONFIG" \
    --slurpfile sec "$KOKORO_SECRETS" >"$tmp/Caddyfile"
grep -Fx 'cdn.example.com {' "$tmp/Caddyfile" >/dev/null
grep -Fx 'split.example.com {' "$tmp/Caddyfile" >/dev/null
[[ "$(grep -Fc 'reverse_proxy 127.0.0.1:8444' "$tmp/Caddyfile")" == 2 ]]
kokoro_cfg_set_str '.inbound.tls.split_domain' ''

kokoro_cfg_set '.inbound.xhttp_split' true
kokoro_xhttp_split_check
render >"$tmp/server.json"
jq -e '
    .inbounds[0] as $front | .inbounds[1] as $back
    | $front.listen == "127.0.0.1" and $front.port == 8443
      and $front.streamSettings.network == "raw" and $front.streamSettings.security == "reality"
      and $front.settings == {clients:[],decryption:"none",fallbacks:[
        {dest:"127.0.0.1:8444",xver:0}]}
      and $back.listen == "127.0.0.1" and $back.port == 8444
      and $back.streamSettings.security == "none" and $back.streamSettings.network == "xhttp"
      and ($back.streamSettings.sockopt.trustedXForwardedFor | length == 0)
      and $back.settings.decryption != "none"
' "$tmp/server.json" >/dev/null
profile cdn-h3=203.0.113.5 reality=2001:db8::42 >"$tmp/cdn-up.json"
profile reality=2001:db8::42 cdn-h2 >"$tmp/cdn-down.json"
profile reality=203.0.113.3 reality=2001:db8::42 >"$tmp/direct-split.json"
jq -e '
    .outbounds[0] | .settings.vnext[0].address == "203.0.113.5"
    and (.streamSettings | .tlsSettings.alpn == ["h3"]
      and (.xhttpSettings | .sessionIDTable == "Base62" and .xPaddingKey == "v"
        and .path == .downloadSettings.xhttpSettings.path
        and .downloadSettings.xhttpSettings.xPaddingKey == "v"
        and .downloadSettings.address == "2001:db8::42"
        and .downloadSettings.security == "reality"))
' "$tmp/cdn-up.json" >/dev/null
jq -e '.outbounds[0] | .settings.vnext[0].address == "2001:db8::42"
    and (.streamSettings | .security == "reality"
      and .xhttpSettings.sessionIDTable == "Base62"
      and .xhttpSettings.downloadSettings.tlsSettings.alpn == ["h2"])' "$tmp/cdn-down.json" >/dev/null

if [[ -n "${XRAY_BIN:-}" ]]; then
    for cfg in "$tmp"/*.json; do "$XRAY_BIN" run -test -config "$cfg"; done
fi

kokoro_cfg_set_str '.inbound.tls.cdn_domain' www.cloudflare.com
fails profile cdn-h2 reality=2001:db8::42
kokoro_cfg_set_str '.inbound.transport' raw
fails profile cdn-h2
echo "xhttp-split: render, profile matrix, and rejection checks passed"
