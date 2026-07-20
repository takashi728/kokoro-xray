#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_XRAY="$(command -v xray || true)"
tmp_home="$(mktemp -d)"
state="${tmp_home}/.kokoro-xray"
fake_bin="${tmp_home}/bin"
install -d -m 700 "$state" "$fake_bin"

cat >"${fake_bin}/xray" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    uuid)
        printf '%s\n' '47711c8f-48a5-4e84-941b-105fc3e21fe4'
        ;;
    vlessenc)
        short="$(printf 'S%.0s' {1..43})"
        pq_dec="$(printf 'D%.0s' {1..86})"
        pq_enc="$(printf 'E%.0s' {1..1579})"
        cat <<OUTPUT
Authentication: X25519, not Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.${short}"
"encryption": "mlkem768x25519plus.native.0rtt.${short}"
Authentication: ML-KEM-768, Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.${pq_dec}"
"encryption": "mlkem768x25519plus.native.0rtt.${pq_enc}"
OUTPUT
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "${fake_bin}/xray"

cp "${ROOT}/config.defaults.json" "${state}/config.json"
cp "${ROOT}/secrets.defaults.json" "${state}/secrets.json"
jq --arg bin "${fake_bin}/xray" '.role = "exit" | .paths.xray_bin = $bin' \
    "${state}/config.json" >"${state}/config.tmp"
mv "${state}/config.tmp" "${state}/config.json"

HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/keys.sh"
source "${KOKORO_ROOT}/lib/relay.sh"
kokoro_gen_exit_vless_secrets

decryption="$(kokoro_sec '.multinode.exit_vless_decryption')"
encryption="$(kokoro_sec '.multinode.exit_vless_encryption')"
[[ "${#decryption}" -eq 117 ]]
[[ "${#encryption}" -eq 1610 ]]

bundle="$(kokoro_relay_export_bundle '203.0.113.2')"
printf '%s' "$bundle" | jq -e '.transport == "vless-pqc" and .exit_port == 51820' >/dev/null

kokoro_cfg_set_str '.role' 'edge'
kokoro_cfg_set '.multinode.enabled' 'false'
kokoro_sec_set_str '.multinode.exit_vless_uuid' ''
kokoro_sec_set_str '.multinode.exit_vless_encryption' ''
kokoro_relay_import_bundle "$bundle"
[[ "$(kokoro_cfg '.multinode.enabled')" == "true" ]]
[[ "$(kokoro_cfg '.multinode.exit_ip')" == "203.0.113.2" ]]
[[ "$(kokoro_sec '.multinode.exit_vless_uuid')" == "47711c8f-48a5-4e84-941b-105fc3e21fe4" ]]
[[ "${#encryption}" -eq 1610 ]]
SCRIPT
echo "pq_key_and_bundle OK"

if [[ -n "$REAL_XRAY" ]]; then
    real_home="$(mktemp -d)"
    real_state="${real_home}/.kokoro-xray"
    install -d -m 700 "$real_state"
    cp "${ROOT}/config.defaults.json" "${real_state}/config.json"
    cp "${ROOT}/secrets.defaults.json" "${real_state}/secrets.json"
    jq --arg bin "$REAL_XRAY" '.role = "exit" | .multinode.edge_ip = "198.51.100.10" | .paths.xray_bin = $bin' \
        "${real_state}/config.json" >"${real_state}/config.tmp"
    mv "${real_state}/config.tmp" "${real_state}/config.json"

    HOME="$real_home" KOKORO_ROOT="$ROOT" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/keys.sh"
kokoro_gen_exit_vless_secrets
SCRIPT

    jq --slurpfile generated "${real_state}/secrets.json" \
        '.multinode = $generated[0].multinode' \
        "${ROOT}/.github/fixtures/edge-secrets.json" >"${real_home}/edge-secrets.json"

    jq -n -f "${ROOT}/lib/render.jq" \
        --slurpfile cfg "${ROOT}/.github/fixtures/edge-config.json" \
        --slurpfile sec "${real_home}/edge-secrets.json" \
        >"${real_home}/edge.json"
    jq -n -f "${ROOT}/lib/render.jq" \
        --slurpfile cfg "${ROOT}/.github/fixtures/exit-config.json" \
        --slurpfile sec "${real_state}/secrets.json" \
        >"${real_home}/exit.json"

    "$REAL_XRAY" run -test -config "${real_home}/edge.json"
    "$REAL_XRAY" run -test -config "${real_home}/exit.json"
    rm -rf "$real_home"
    echo "pq_xray_config OK"
fi

rm -rf "$tmp_home"
echo "pq-relay-test OK"
