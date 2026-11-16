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

check_kernel() {
    local id="$1" ver="$2" release="$3" expected="$4" got
    got="$(
        KOKORO_OS_ID="$id" KOKORO_OS_VER="$ver" KOKORO_TEST_KREL="$release" \
            KOKORO_ROOT="$ROOT" bash -c '
                source "$KOKORO_ROOT/lib/caddy.sh"
                source "$KOKORO_ROOT/lib/health.sh"
                uname() { printf "%s\n" "$KOKORO_TEST_KREL"; }
                sysctl() { printf "0\n"; }
                kokoro_health_kernel_cve
            '
    )"
    if [[ "$expected" == "warn" ]]; then
        [[ -n "$got" ]]
    else
        [[ -z "$got" ]]
    fi
}

check_kernel ubuntu 24.04 6.8.0-149-generic ok
check_kernel ubuntu 24.04 6.8.0-148-generic warn
check_kernel ubuntu 22.04 5.15.0-203-generic ok
check_kernel ubuntu 22.04 5.15.0-202-generic warn
check_kernel debian 12 6.1.190-amd64 ok
check_kernel debian 12 6.1.189-amd64 warn

rm -rf "$tmp_home"
echo "health-test OK"
