#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${ROOT}/.github/fixtures"
tmp_home="$(mktemp -d)"
install -d -m 700 "${tmp_home}/.kokoro-xray"

jq '.inbound.mode = "tls" | .multinode.enabled = false' \
    "${FIX}/edge-config.json" >"${tmp_home}/.kokoro-xray/config.json"
cp "${FIX}/edge-secrets.json" "${tmp_home}/.kokoro-xray/secrets.json"

out="$(HOME="$tmp_home" KOKORO_ROOT="$ROOT" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/health.sh"
kokoro_health
SCRIPT
)"

printf '%s\n' "$out" | grep -q 'TLS mode client note'
printf '%s\n' "$out" | grep -q 'Please use HApp'
printf '%s\n' "$out" | grep -q 'kokoro-xray link --json tls'
printf '%s\n' "$out" | grep -q 'vless enc:'

rm -rf "$tmp_home"
echo "health-test OK"
