#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=hy.example.com \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1

jq --arg cert "$TMP/cert.pem" --arg key "$TMP/key.pem" '
  .role = "edge"
  | .inbound.mode = "reality"
  | .inbound.hysteria.enabled = true
  | .inbound.hysteria.domain = "hy.example.com"
  | .inbound.hysteria.acme_email = "admin@example.com"
  | .paths.hysteria_cert = $cert
  | .paths.hysteria_key = $key
' "$ROOT/config.defaults.json" >"$TMP/config.json"

jq '
  .inbound.uuid = "11111111-1111-4111-8111-111111111111"
  | .inbound.xhttp_path = "/test"
  | .inbound.vless_encryption.decryption = "none"
  | .inbound.reality.private_key = "KHF8yTqYvT0t4JihrG0dtPDnXwb8OVDS18pcZboL-Tw"
  | .inbound.reality.short_ids = ["01234567"]
  | .inbound.hysteria.auth = "aaaaaaaa"
  | .inbound.hysteria.obfs_password = "bbbbbbbb"
' "$ROOT/secrets.defaults.json" >"$TMP/secrets.json"

jq -n -f "$ROOT/lib/render.jq" \
    --slurpfile cfg "$TMP/config.json" \
    --slurpfile sec "$TMP/secrets.json" >"$TMP/xray.json"
jq -n -r -f "$ROOT/lib/caddy.jq" \
    --slurpfile cfg "$TMP/config.json" \
    --slurpfile sec "$TMP/secrets.json" >"$TMP/Caddyfile"

jq -e '
  any(.inbounds[];
    .tag == "HYSTERIA2_IN"
    and .port == "443,20000-20020"
    and .streamSettings.method == "hysteria"
    and .streamSettings.finalmask.quicParams.bbrProfile == "aggressive"
    and .streamSettings.finalmask.udp[0].settings.packetSize == "512-1200")
  and any(.inbounds[]; .tag == "REALITY_XHTTP_IN" and .listen == "127.0.0.1" and .port == 8443)
' "$TMP/xray.json" >/dev/null
grep -q 'protocols h1 h2' "$TMP/Caddyfile"
! grep -q 'protocols.*h3' "$TMP/Caddyfile"

mkdir -p "$TMP/.kokoro-xray"
cp "$TMP/config.json" "$TMP/.kokoro-xray/config.json"
cp "$TMP/secrets.json" "$TMP/.kokoro-xray/secrets.json"
rules="$(
    HOME="$TMP" KOKORO_ROOT="$ROOT" bash -c '
      source "$KOKORO_ROOT/lib/firewall.sh"
      kokoro_firewall_ufw_allow() { printf "%s\n" "$1"; }
      kokoro_firewall_service_rules
    '
)"
grep -qx '443/udp' <<<"$rules"
grep -qx '20000:20020/udp' <<<"$rules"

if [[ -n "${XRAY_BIN:-}" ]]; then
    "$XRAY_BIN" run -test -config "$TMP/xray.json"
fi

echo "hysteria render: ok"
