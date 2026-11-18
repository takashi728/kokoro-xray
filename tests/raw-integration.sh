#!/usr/bin/env bash
# Optional live test: Caddy+caddy-l4 and the PrivateBin test container must exist.
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
: "${CADDY_BIN:?set CADDY_BIN to Caddy with caddy-l4}"
XRAY_BIN="${XRAY_BIN:-/usr/bin/xray}"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
TMP="$(mktemp -d)"
pids=()
cleanup() {
    local status=$? pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    if [[ "$status" -ne 0 ]]; then
        for log in "$TMP/server.log" "$TMP/client.log" "$TMP/caddy.log" "$TMP/reality-server.log" "$TMP/reality-client.log"; do
            [[ ! -f "$log" ]] || tail -n 40 "$log" >&2
        done
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP" KOKORO_ROOT="$ROOT"
mkdir -p "$HOME/.kokoro-xray"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=direct.example \
    -addext 'subjectAltName=DNS:direct.example' \
    -keyout "$TMP/tls.key" -out "$TMP/tls.crt" >/dev/null 2>&1
jq --arg cert "$TMP/tls.crt" --arg key "$TMP/tls.key" '
    .role = "edge" | .inbound.transport = "raw" | .inbound.mode = "tls"
    | .inbound.tls.domain = "direct.example" | .inbound.tls.acme_email = "test@example.com"
    | .inbound.vless_encryption.enabled = true | .inbound.hysteria.enabled = false
    | .paths.tls_cert = $cert | .paths.tls_key = $key
' "$ROOT/config.defaults.json" >"$HOME/.kokoro-xray/config.json"
cp "$ROOT/.github/fixtures/edge-secrets.json" "$HOME/.kokoro-xray/secrets.json"
keys="$("$XRAY_BIN" vlessenc)"
decryption="$(awk -F'"' '$2 == "decryption" {print $4; exit}' <<<"$keys")"
encryption="$(awk -F'"' '$2 == "encryption" {print $4; exit}' <<<"$keys")"
jq --arg dec "$decryption" --arg enc "$encryption" '
    .inbound.vless_encryption.decryption = $dec | .inbound.vless_encryption.encryption = $enc
' "$HOME/.kokoro-xray/secrets.json" >"$TMP/secrets.json"
mv "$TMP/secrets.json" "$HOME/.kokoro-xray/secrets.json"
jq -n -f "$ROOT/lib/render.jq" --slurpfile cfg "$HOME/.kokoro-xray/config.json" \
    --slurpfile sec "$HOME/.kokoro-xray/secrets.json" | jq '
    .inbounds[0].port = 18444
    | .inbounds[0].settings.fallbacks[0].dest = "127.0.0.1:18080"
    | .routing.rules = [{type:"field",network:"tcp,udp",outboundTag:"DIRECT"}]
    | .outbounds |= map(if .tag == "DIRECT" then
        .settings.finalRules = [{action:"allow",ip:["127.0.0.1/32"]}] else . end)
' >"$TMP/server.json"
jq -nr -f "$ROOT/lib/caddy.jq" --slurpfile cfg "$HOME/.kokoro-xray/config.json" \
    --slurpfile sec "$HOME/.kokoro-xray/secrets.json" >"$TMP/Caddyfile"
"$CADDY_BIN" adapt --config "$TMP/Caddyfile" >"$TMP/caddy-adapted.json"
# Keep production routing, changing only test ports, ACME, and the test certificate.
jq --arg cert "$TMP/tls.crt" --arg key "$TMP/tls.key" --arg admin "unix/$TMP/admin.sock" '
    walk(if type == "string" then
        if . == ":443" then "127.0.0.1:14443"
        elif . == ":80" then "127.0.0.1:18000"
        elif . == "127.0.0.1:8444" then "127.0.0.1:18444"
        elif . == "tcp/127.0.0.1:8444" then "tcp/127.0.0.1:18444"
        elif . == "127.0.0.1:8080" then "127.0.0.1:18080"
        elif . == "127.0.0.1:8081" then "127.0.0.1:18081"
        else . end else . end)
    | .admin.listen = $admin
    | .storage = {module:"file_system",root:($cert | sub("/tls.crt$";"/caddy-data"))}
    | .apps.tls.automation.policies = []
    | .apps.tls.certificates.load_files = [{certificate:$cert,key:$key}]
    | .apps.http.servers |= with_entries(.value.automatic_https.disable = true)
' "$TMP/caddy-adapted.json" >"$TMP/caddy.json"
source "$ROOT/lib/link.sh"
kokoro_link_tls_json | jq --arg cert "$TMP/tls.crt" '
    .inbounds = [.inbounds[0] | .port = 19108]
    | .outbounds[0].settings.vnext[0].address = "127.0.0.1"
    | .outbounds[0].settings.vnext[0].port = 14443
    | .outbounds[0].streamSettings.tlsSettings.certificates = [{certificateFile:$cert,usage:"verify"}]
    | .routing.rules = [{type:"field",network:"tcp,udp",outboundTag:"kokoro-tls"}]
' >"$TMP/client.json"
"$XRAY_BIN" run -config "$TMP/server.json" >"$TMP/server.log" 2>&1 &
pids+=("$!")
"$CADDY_BIN" run --config "$TMP/caddy.json" >"$TMP/caddy.log" 2>&1 &
pids+=("$!")
"$XRAY_BIN" run -config "$TMP/client.json" >"$TMP/client.log" 2>&1 &
pids+=("$!")
for i in $(seq 1 30); do
    if curl --noproxy '*' -fsS --max-time 2 --cacert "$TMP/tls.crt" \
        --resolve direct.example:14443:127.0.0.1 https://direct.example:14443/ \
        >"$TMP/page" 2>/dev/null; then break; fi
    sleep 0.2
done
for protocol in --http1.1 --http2; do
    version="$(curl --noproxy '*' "$protocol" -fsS --max-time 10 --cacert "$TMP/tls.crt" \
        --resolve direct.example:14443:127.0.0.1 https://direct.example:14443/ \
        -o "$TMP/page" -w '%{http_version}')"
    if [[ "$protocol" == --http2 ]]; then [[ "$version" == 2 ]]
    else [[ "$version" == 1.1 ]]; fi
    grep -q '<title>PrivateBin' "$TMP/page"
done
if [[ -n "$NODE_BIN" ]]; then
    PRIVATEBIN_TEST_CA="$TMP/tls.crt" "$NODE_BIN" "$ROOT/tests/privatebin-paste.mjs"
fi
if ! curl --noproxy '' --socks5 127.0.0.1:19108 -fsS --max-time 10 \
    --cacert "$TMP/tls.crt" --resolve direct.example:14443:127.0.0.1 \
    https://direct.example:14443/ >"$TMP/proxied"; then
    exit 1
fi
grep -q '<title>PrivateBin' "$TMP/proxied"

# REALITY uses the already-running local HTTPS fixture as its certificate target.
# This bypasses target discovery only in this isolated protocol test.
reality_keys="$("$XRAY_BIN" x25519)"
private_key="$(awk -F': *' 'tolower($1) ~ /private.*key|privatekey/ {print $2; exit}' <<<"$reality_keys")"
public_key="$(awk -F': *' 'tolower($1) ~ /public.*key|publickey|password/ {print $2; exit}' <<<"$reality_keys")"
kokoro_sec_set_str '.inbound.reality.private_key' "$private_key"
kokoro_sec_set_str '.inbound.reality.public_key' "$public_key"
kokoro_cfg_set_str '.inbound.mode' reality
kokoro_cfg_set_str '.inbound.reality.dest' '127.0.0.1:14443'
kokoro_cfg_set '.inbound.reality.server_names' '["direct.example"]'
jq -n -f "$ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" \
    --slurpfile sec "$KOKORO_SECRETS" | jq '
    .inbounds[0].listen = "127.0.0.1" | .inbounds[0].port = 18443
    | .routing.rules = [{type:"field",network:"tcp,udp",outboundTag:"DIRECT"}]
    | .outbounds |= map(if .tag == "DIRECT" then
        .settings.finalRules = [{action:"allow",ip:["127.0.0.1/32"]}] else . end)
' >"$TMP/reality-server.json"
KOKORO_PUBLIC_ADDRESS=127.0.0.1 kokoro_link_reality_json | jq '
    .inbounds = [.inbounds[0] | .port = 19109]
    | .outbounds[0].settings.vnext[0].port = 18443
    | .routing.rules = [{type:"field",network:"tcp,udp",outboundTag:"kokoro-reality"}]
' >"$TMP/reality-client.json"
"$XRAY_BIN" run -config "$TMP/reality-server.json" >"$TMP/reality-server.log" 2>&1 &
pids+=("$!")
"$XRAY_BIN" run -config "$TMP/reality-client.json" >"$TMP/reality-client.log" 2>&1 &
pids+=("$!")
sleep 0.5
curl --noproxy '' --socks5 127.0.0.1:19109 -fsS --max-time 15 \
    --cacert "$TMP/tls.crt" --resolve direct.example:14443:127.0.0.1 \
    https://direct.example:14443/ >"$TMP/reality-proxied"
grep -q '<title>PrivateBin' "$TMP/reality-proxied"
echo 'raw-integration: HTTP/1.1 and HTTP/2 fallback, RAW TLS Vision, and RAW REALITY Vision + VLESS Encryption passed'
