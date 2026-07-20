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

jq '.version = "0.2.0" | del(.inbound.vless_encryption)' \
    "${ROOT}/config.defaults.json" >"${state}/config.json"
jq '.version = "0.2.0" | .inbound.uuid = "preserve-me" | del(.inbound.vless_encryption)' \
    "${ROOT}/secrets.defaults.json" >"${state}/secrets.json"

HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/common.sh"
kokoro_ensure_state
[[ "$(kokoro_cfg '.version')" == "0.3.0" ]]
[[ "$(kokoro_sec '.version')" == "0.3.0" ]]
[[ "$(kokoro_cfg '.inbound.vless_encryption.enabled')" == "false" ]]
[[ "$(kokoro_sec '.inbound.uuid')" == "preserve-me" ]]
[[ -z "$(kokoro_sec '.inbound.vless_encryption.decryption')" ]]
SCRIPT
echo "migration_safe_default OK"

rm -rf "$tmp_home"
echo "vless-encryption-test OK"
