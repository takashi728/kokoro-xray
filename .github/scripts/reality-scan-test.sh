#!/usr/bin/env bash
# Unit-style test for reality scan (blocked names + normalize)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export KOKORO_ROOT="$ROOT"
source "${ROOT}/lib/reality-scan.sh"

test_blocked() {
    kokoro_reality_blocked "www.apple.com" && echo "block apple OK"
    kokoro_reality_blocked "gateway.icloud.com" && echo "block icloud OK"
    kokoro_reality_blocked "WWW.MICROSOFT.COM" && echo "block microsoft OK"
    kokoro_reality_blocked "example.cn" && echo "block cn OK"
    kokoro_reality_blocked "example.ru" && echo "block ru OK"
    kokoro_reality_blocked "example.ir" && echo "block ir OK"
    ! kokoro_reality_blocked "www.sky.com" && echo "allow sky OK"
}

test_normalize() {
    [[ "$(kokoro_reality_normalize_host 'https://www.sky.com/path')" == "www.sky.com" ]]
    echo "normalize OK"
}

test_seeds() {
    local host
    while IFS= read -r host; do
        [[ -z "$host" || "$host" == \#* ]] && continue
        ! kokoro_reality_blocked "$host"
    done <"${ROOT}/data/reality-seeds.txt"
    echo "seed policy OK"
}

test_apply_host() {
    local tmp_home cfg
    tmp_home="$(mktemp -d)"
    install -d -m 700 "${tmp_home}/.kokoro-xray"
    cfg="${tmp_home}/.kokoro-xray/config.json"
    cp "${ROOT}/config.defaults.json" "$cfg"
    cp "${ROOT}/secrets.defaults.json" "${tmp_home}/.kokoro-xray/secrets.json"

    HOME="$tmp_home" bash -c "
        export KOKORO_ROOT='${ROOT}'
        source '${ROOT}/lib/common.sh'
        source '${ROOT}/lib/reality-scan.sh'
        kokoro_reality_apply_host 'www.example.com'
    "
    [[ "$(jq -r '.inbound.reality.dest' "$cfg")" == "www.example.com:443" ]]
    [[ "$(jq -r '.inbound.reality.server_names[0]' "$cfg")" == "www.example.com" ]]
    rm -rf "$tmp_home"
    echo "apply_host OK"
}

test_blocked
test_normalize
test_seeds
test_apply_host

# Live probe (optional, needs network)
if [[ "${KOKORO_LIVE_SCAN:-}" == "1" ]]; then
    out="$(kokoro_reality_validate_one github.com)"
    echo "$out" | grep -q '^OK' && echo "live debian OK" || { echo "live fail: $out"; exit 1; }
fi

echo "reality-scan-test OK"
