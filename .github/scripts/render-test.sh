#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${ROOT}/.github/fixtures"
OUT="/tmp/kokoro-render-test"
mkdir -p "$OUT"

echo "== edge xray =="
jq -n -f "${ROOT}/lib/render.jq" \
    --slurpfile cfg "${FIX}/edge-config.json" \
    --slurpfile sec "${FIX}/edge-secrets.json" \
    >"${OUT}/edge-xray.json"
jq -e '.inbounds | length == 2' "${OUT}/edge-xray.json" >/dev/null
jq -e '[.inbounds[] | select(.protocol == "hysteria")] | length == 0' "${OUT}/edge-xray.json" >/dev/null
jq -e '(.outbounds | map(.tag) | index("TOR")) | not' "${OUT}/edge-xray.json" >/dev/null
jq -e '.outbounds | map(.tag) | index("WG_TO_EXIT")' "${OUT}/edge-xray.json" >/dev/null
jq -e '.routing.rules[-1].outboundTag == "WG_TO_EXIT"' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="REALITY_XHTTP_IN") | .listen == "127.0.0.1"' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="REALITY_XHTTP_IN") | .settings.decryption | startswith("mlkem768x25519plus.native.600s.")' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="TLS_XHTTP_IN") | .settings.decryption | startswith("mlkem768x25519plus.native.600s.")' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="REALITY_XHTTP_IN") | .streamSettings.xhttpSettings.mode == null' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="TLS_XHTTP_IN") | .streamSettings.xhttpSettings.mode == "auto"' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="TLS_XHTTP_IN") | .streamSettings.xhttpSettings.xPaddingObfsMode == true' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="TLS_XHTTP_IN") | .streamSettings.xhttpSettings.xPaddingKey == "v"' "${OUT}/edge-xray.json" >/dev/null
jq -e '.inbounds[] | select(.tag=="TLS_XHTTP_IN") | .streamSettings.xhttpSettings.xmux.maxConcurrency == "5-10"' "${OUT}/edge-xray.json" >/dev/null

echo "== edge single-node xray =="
jq -n -f "${ROOT}/lib/render.jq" \
    --slurpfile cfg "${FIX}/edge-single-config.json" \
    --slurpfile sec "${FIX}/edge-secrets.json" \
    >"${OUT}/edge-single-xray.json"
jq -e '(.outbounds | map(.tag) | index("WG_TO_EXIT")) | not' "${OUT}/edge-single-xray.json" >/dev/null
jq -e '.routing.rules[0].domain[0] == "geosite:google"' "${OUT}/edge-single-xray.json" >/dev/null
jq -e '.routing.rules[0].domain | index("domain:googleapis.cn")' "${OUT}/edge-single-xray.json" >/dev/null
jq -e '.routing.rules[0].domain | index("domain:gstatic.cn")' "${OUT}/edge-single-xray.json" >/dev/null
jq -e '.routing.rules | map(select(.domain[]? == "regexp:.*\\.ru$")) | length > 0' "${OUT}/edge-single-xray.json" >/dev/null
jq -e '.routing.rules | map(select(.domain[]? == "regexp:.*\\.su$")) | length > 0' "${OUT}/edge-single-xray.json" >/dev/null
jq -e '.routing.rules | map(select(.ip[]? == "geoip:ru")) | length > 0' "${OUT}/edge-single-xray.json" >/dev/null
jq -e '.routing.rules[-1].outboundTag == "DIRECT"' "${OUT}/edge-single-xray.json" >/dev/null

echo "== edge VLESS Encryption disabled =="
jq '.inbound.vless_encryption.enabled = false' "${FIX}/edge-single-config.json" >"${OUT}/edge-disabled-config.json"
jq -n -f "${ROOT}/lib/render.jq" \
    --slurpfile cfg "${OUT}/edge-disabled-config.json" \
    --slurpfile sec "${FIX}/edge-secrets.json" \
    >"${OUT}/edge-disabled-xray.json"
jq -e '.inbounds[0].settings.decryption == "none"' "${OUT}/edge-disabled-xray.json" >/dev/null

echo "== edge single-node xray with static proxy =="
jq '.static_proxy = {enabled: true, protocol: "socks", address: "203.0.113.10", port: 1080}' \
    "${FIX}/edge-single-config.json" >"${OUT}/edge-sp-config.json"
jq '.static_proxy = {username: "user1", password: "pass1"}' \
    "${FIX}/edge-secrets.json" >"${OUT}/edge-sp-secrets.json"
jq -n -f "${ROOT}/lib/render.jq" \
    --slurpfile cfg "${OUT}/edge-sp-config.json" \
    --slurpfile sec "${OUT}/edge-sp-secrets.json" \
    >"${OUT}/edge-sp-xray.json"
jq -e '.outbounds | map(.tag) | index("STATIC_PROXY")' "${OUT}/edge-sp-xray.json" >/dev/null
jq -e '.outbounds[] | select(.tag=="STATIC_PROXY") | .protocol == "socks"' "${OUT}/edge-sp-xray.json" >/dev/null
jq -e '.outbounds[] | select(.tag=="STATIC_PROXY") | .settings.servers[0].address == "203.0.113.10"' "${OUT}/edge-sp-xray.json" >/dev/null
jq -e '.outbounds[] | select(.tag=="STATIC_PROXY") | .settings.servers[0].users[0].user == "user1"' "${OUT}/edge-sp-xray.json" >/dev/null
jq -e '.routing.rules[-1].outboundTag == "STATIC_PROXY"' "${OUT}/edge-sp-xray.json" >/dev/null
jq -e '.routing.rules | map(select(.domain[]? == "geosite:google")) | length == 0' "${OUT}/edge-sp-xray.json" >/dev/null

echo "== edge caddy =="
jq -n -r -f "${ROOT}/lib/caddy.jq" \
    --slurpfile cfg "${FIX}/edge-config.json" \
    --slurpfile sec "${FIX}/edge-secrets.json" \
    >"${OUT}/Caddyfile"
grep -q 'layer4' "${OUT}/Caddyfile"
grep -q 'listener_wrappers' "${OUT}/Caddyfile"
grep -q 'proxy tcp/127.0.0.1:8443' "${OUT}/Caddyfile"
grep -q 'header_up Kokoro-Trusted-XFF 1' "${OUT}/Caddyfile"
jq -e '.inbounds[] | select(.tag=="TLS_XHTTP_IN") | .streamSettings.sockopt.trustedXForwardedFor == ["Kokoro-Trusted-XFF"]' "${OUT}/edge-xray.json" >/dev/null

echo "== exit xray =="
jq -n -f "${ROOT}/lib/render.jq" \
    --slurpfile cfg "${FIX}/exit-config.json" \
    --slurpfile sec "${FIX}/exit-secrets.json" \
    >"${OUT}/exit-xray.json"
jq -e '.inbounds[0].protocol == "wireguard"' "${OUT}/exit-xray.json" >/dev/null
jq -e '.outbounds | map(.tag) | index("TOR")' "${OUT}/exit-xray.json" >/dev/null
jq -e '.routing.rules[0].outboundTag == "TOR"' "${OUT}/exit-xray.json" >/dev/null
jq -e '.routing.rules[-1].outboundTag == "DIRECT"' "${OUT}/exit-xray.json" >/dev/null

if command -v xray >/dev/null 2>&1; then
    echo "== xray -test =="
    xray run -test -config "${OUT}/edge-xray.json"
    xray run -test -config "${OUT}/exit-xray.json"
else
    echo "skip xray -test (binary not installed)"
fi

echo "render-test OK"
