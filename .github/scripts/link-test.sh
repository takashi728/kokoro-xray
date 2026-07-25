#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${ROOT}/.github/fixtures"
tmp_home="$(mktemp -d)"
install -d -m 700 "${tmp_home}/.kokoro-xray"
cp "${FIX}/edge-config.json" "${tmp_home}/.kokoro-xray/config.json"
cp "${FIX}/edge-secrets.json" "${tmp_home}/.kokoro-xray/secrets.json"

HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/link.sh"
kokoro_ensure_state >/dev/null

expected_pbk="$(kokoro_sec '.inbound.reality.public_key')"
expected_encryption="$(kokoro_sec '.inbound.vless_encryption.encryption')"
reality="$(kokoro_link_reality_url | tr -d '\n')"
[[ "$reality" == vless://* ]]
[[ "$reality" == *"security=reality"* ]]
[[ "$reality" == *"type=xhttp"* ]]
[[ "$reality" == *"pbk=${expected_pbk}"* ]]
[[ "$reality" == *"encryption=${expected_encryption}"* ]]

tls="$(kokoro_link_tls_url | tr -d '\n')"
[[ "$tls" == vless://* ]]
[[ "$tls" == *"security=tls"* ]]
[[ "$tls" == *"cdn.example.com"* ]]
[[ "$tls" == *"host=cdn.example.com"* ]]
[[ "$tls" == *"sni=cdn.example.com"* ]]
[[ "$tls" == *"fp=chrome"* ]]
[[ "$tls" == *"alpn=h2"* ]]
[[ "$tls" == *"encryption=${expected_encryption}"* ]]

tls_json="$(kokoro_link_tls_json)"
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].tag == "kokoro-tls"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.security == "tls"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.tlsSettings.serverName == "cdn.example.com"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.tlsSettings.fingerprint == "chrome"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.tlsSettings.alpn[0] == "h2"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.tlsSettings.echConfigList == "https://cloudflare-dns.com/dns-query"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.xhttpSettings.mode == "auto"' >/dev/null
printf '%s\n' "$tls_json" | jq -e --arg encryption "$expected_encryption" '.outbounds[0].settings.vnext[0].users[0].encryption == $encryption' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.xhttpSettings.xPaddingObfsMode == true' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.xhttpSettings.xmux.maxConnections == "6"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.outbounds[0].streamSettings.xhttpSettings.xmux.maxConcurrency == null' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.dns.servers == ["https://cloudflare-dns.com/dns-query"]' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.dns.queryStrategy == "UseIP"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[0].outboundTag == "BLOCK"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[0].domain | index("geosite:category-ads-all")' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[1].outboundTag == "BLOCK"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[1].domain | index("domain:dns.google")' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[2].outboundTag == "BLOCK"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[2].ip | index("8.8.8.8")' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[3].outboundTag == "kokoro-tls"' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[3].domain | index("domain:googleapis.cn")' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[3].domain | index("domain:gstatic.cn")' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules | map(select(.domain[]? == "regexp:.*\\.ru$")) | length > 0' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules | map(select(.ip[]? == "geoip:cn")) | length > 0' >/dev/null
printf '%s\n' "$tls_json" | jq -e '.routing.rules[-1].outboundTag == "kokoro-tls"' >/dev/null

cli_tls_json="$(kokoro_link_show --json tls)"
printf '%s\n' "$cli_tls_json" | jq -e '.outbounds[0].tag == "kokoro-tls"' >/dev/null

if command -v xray >/dev/null 2>&1; then
    printf '%s\n' "$cli_tls_json" >"${HOME}/.kokoro-xray/client-tls.json"
    xray run -test -config "${HOME}/.kokoro-xray/client-tls.json"
fi

kokoro_cfg_set '.inbound.vless_encryption.enabled' 'false'
disabled_tls="$(kokoro_link_tls_url | tr -d '\n')"
[[ "$disabled_tls" == *"encryption=none"* ]]

kokoro_cfg_set '.inbound.hysteria.enabled' 'true'
kokoro_cfg_set_str '.inbound.hysteria.domain' 'hy2.example.com'
kokoro_cfg_set_str '.inbound.hysteria.ports' '443,20000-20020'
kokoro_sec_set_str '.inbound.hysteria.auth' 'test-auth'
kokoro_sec_set_str '.inbound.hysteria.obfs_password' 'test-obfs'
hysteria="$(kokoro_link_hysteria_url | tr -d '\n')"
[[ "$hysteria" == hysteria2://test-auth@hy2.example.com:443/\?* ]]
[[ "$hysteria" != *":443,20000-20020"* ]]
[[ "$hysteria" == *"sni=hy2.example.com"* ]]

hysteria_json="$(kokoro_link_show --json hysteria)"
printf '%s\n' "$hysteria_json" | jq -e '.outbounds[0].settings.port == 443' >/dev/null
printf '%s\n' "$hysteria_json" | jq -e '.outbounds[0].streamSettings.finalmask.quicParams.udpHop.ports == "443,20000-20020"' >/dev/null
printf '%s\n' "$hysteria_json" | jq -e '.outbounds[0].streamSettings.finalmask.quicParams.udpHop.interval == "10-20"' >/dev/null
printf '%s\n' "$hysteria_json" | jq -e '.outbounds[0].streamSettings.tlsSettings.serverName == "hy2.example.com"' >/dev/null

if command -v xray >/dev/null 2>&1; then
    printf '%s\n' "$hysteria_json" >"${HOME}/.kokoro-xray/client-hysteria.json"
    xray run -test -config "${HOME}/.kokoro-xray/client-hysteria.json"
fi
SCRIPT

rm -rf "$tmp_home"
echo "link-test OK"
