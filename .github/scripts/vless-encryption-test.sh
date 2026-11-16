#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp_home="$(mktemp -d)"
state="${tmp_home}/.kokoro-xray"
fake_xray="${tmp_home}/xray"
install -d -m 700 "$state"

cat >"$fake_xray" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
Choose one Authentication to use, do not mix them.

Authentication: X25519, not Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.yLeObCG7TCZsVEI3UmOm0roWhykIsmWZbxn24DWAqHk"
"encryption": "mlkem768x25519plus.native.0rtt.IJjqYERNUsDHHchKixEPcbed8p1y9_YFs0binjVEUjQ"

Authentication: ML-KEM-768, Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.wrong-server-key"
"encryption": "mlkem768x25519plus.native.0rtt.wrong-client-key"
OUTPUT
EOF
chmod +x "$fake_xray"

cp "${ROOT}/config.defaults.json" "${state}/config.json"
cp "${ROOT}/secrets.defaults.json" "${state}/secrets.json"
jq --arg bin "$fake_xray" '.role = "edge" | .paths.xray_bin = $bin' \
    "${state}/config.json" >"${state}/config.tmp"
mv "${state}/config.tmp" "${state}/config.json"

HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/keys.sh"
kokoro_gen_vless_encryption_keys
[[ "$(kokoro_sec '.inbound.vless_encryption.decryption')" == "mlkem768x25519plus.native.600s.yLeObCG7TCZsVEI3UmOm0roWhykIsmWZbxn24DWAqHk" ]]
[[ "$(kokoro_sec '.inbound.vless_encryption.encryption')" == "mlkem768x25519plus.native.0rtt.IJjqYERNUsDHHchKixEPcbed8p1y9_YFs0binjVEUjQ" ]]
SCRIPT
echo "key_parse OK"

jq '.version = "0.2.0"
    | del(.inbound.vless_encryption)
    | .inbound.hysteria = {"enabled":true}
    | .multinode.finalmask = true
    | .paths.hysteria_cert = "/old/cert"
    | .paths.hysteria_key = "/old/key"' \
    "${ROOT}/config.defaults.json" >"${state}/config.json"
jq '.version = "0.2.0"
    | .inbound.uuid = "preserve-me"
    | del(.inbound.vless_encryption)
    | .inbound.hysteria = {"auth":"old","obfs_password":"old"}' \
    "${ROOT}/secrets.defaults.json" >"${state}/secrets.json"

HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/common.sh"
kokoro_ensure_state
[[ "$(kokoro_cfg '.version')" == "0.5.0" ]]
[[ "$(kokoro_sec '.version')" == "0.5.0" ]]
jq -e '.version == "0.5.0"' "${KOKORO_ROOT}/config.defaults.json" >/dev/null
jq -e '.version == "0.5.0"' "${KOKORO_ROOT}/secrets.defaults.json" >/dev/null
[[ "$(kokoro_cfg '.inbound.vless_encryption.enabled')" == "false" ]]
[[ "$(kokoro_sec '.inbound.uuid')" == "preserve-me" ]]
[[ -z "$(kokoro_sec '.inbound.vless_encryption.decryption')" ]]
[[ "$(kokoro_cfg '.inbound | has("hysteria")')" == "true" ]]
[[ "$(kokoro_cfg '.multinode | has("finalmask")')" == "true" ]]
[[ "$(kokoro_cfg '.paths | has("hysteria_cert") and has("hysteria_key")')" == "true" ]]
[[ "$(kokoro_sec '.inbound | has("hysteria")')" == "true" ]]
SCRIPT
echo "migration_safe_default OK"

jq '.version = "0.4.0" | .caddy.version = "2.11.3"' \
    "${ROOT}/config.defaults.json" >"${state}/config.json"
HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash -c '
    source "${KOKORO_ROOT}/lib/common.sh"
    kokoro_ensure_state
    [[ "$(kokoro_cfg ".version")" == "0.5.0" ]]
    [[ "$(kokoro_cfg ".caddy.version")" == "2.11.9" ]]
'
echo "caddy_security_migration OK"

tmp_cert="$(mktemp)"
tmp_key="$(mktemp)"
jq --arg cert "$tmp_cert" --arg key "$tmp_key" '
    .role = "edge"
    | .inbound.mode = "reality"
    | .caddy.use_l4 = false
    | .inbound.hysteria = {
        enabled: true,
        domain: "hy2.example.com",
        acme_email: "admin@example.com",
        ports: "443,20000-20020",
        hop_interval: "10-20",
        masquerade: "www.cloudflare.com"
      }
    | .paths.hysteria_cert = $cert
    | .paths.hysteria_key = $key
' "${ROOT}/config.defaults.json" >"${state}/config.json"
jq '.inbound.hysteria = {auth:"auth",obfs_password:"obfs"}' "${ROOT}/secrets.defaults.json" \
    >"${state}/secrets.json"
if HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash -c '
    source "${KOKORO_ROOT}/lib/common.sh"
    source "${KOKORO_ROOT}/lib/preflight.sh"
    kokoro_preflight
' >/dev/null 2>&1; then
    echo "Hysteria2 reality mode unexpectedly accepted without Caddy L4" >&2
    exit 1
fi
rm -f "$tmp_cert" "$tmp_key"
echo "hysteria_l4_guard OK"

rm -rf "$tmp_home"
echo "vless-encryption-test OK"
