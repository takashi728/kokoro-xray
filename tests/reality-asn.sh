#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export KOKORO_ROOT="$ROOT" KOKORO_PUBLIC_ADDRESS=203.0.113.10
export HOME="$TMP" TMP
source "$ROOT/lib/reality-scan.sh"
source "$ROOT/lib/reality-asn.sh"

curl() {
    local resource="" arg
    for arg in "$@"; do
        [[ "$arg" == resource=* ]] && resource="${arg#resource=}"
    done
    if [[ -z "$resource" && "$*" == *https://match.example/* ]]; then
        printf 'HTTP/2 200\r\n\r\n'; return 0
    fi
    if [[ "$*" == *dns-chain* ]]; then
        case "$resource" in
            ipv6.example) jq -cn --arg host "$resource" '{status:"ok",data:{forward_nodes:{($host):["2001:db8::20"]}}}' ;;
            *) jq -cn --arg host "$resource" '{status:"ok",data:{forward_nodes:{($host):["203.0.113.20","2001:db8::20"]}}}' ;;
        esac
        return 0
    fi
    case "$resource" in
        203.0.113.10|203.0.113.20|2001:db8::20)
            printf '{"status":"ok","data":{"asns":[64500]}}' ;;
        203.0.113.30)
            printf '{"status":"ok","data":{"asns":[64501]}}' ;;
        203.0.113.40)
            printf '{"status":"ok","data":{"asns":[64500,64501]}}' ;;
        203.0.113.50)
            printf '{"status":"ok","data":{"asns":[]}}' ;;
        *) return 1 ;;
    esac
}
getent() {
    case "$2" in
        match.example) printf '203.0.113.20 STREAM match.example\n' ;;
        foreign.example) printf '203.0.113.30 STREAM foreign.example\n' ;;
        mixed.example) printf '203.0.113.20 STREAM mixed.example\n203.0.113.30 STREAM mixed.example\n' ;;
        moas.example) printf '203.0.113.40 STREAM moas.example\n' ;;
        unknown.example) printf '203.0.113.50 STREAM unknown.example\n' ;;
        self.example) printf '203.0.113.10 STREAM self.example\n' ;;
        dual.example) printf '2001:db8::20 STREAM dual.example\n203.0.113.20 STREAM dual.example\n' ;;
        ipv6.example) printf '2001:db8::20 STREAM ipv6.example\n' ;;
        203.0.113.10) printf '203.0.113.10 vps.provider.example\n' ;;
        *) return 2 ;;
    esac
}
openssl() {
    printf '%s\n' "$*" >>"$TMP/tls-calls"
    if [[ "$1" == x509 ]]; then
        printf 'X509v3 Subject Alternative Name:\n    DNS:match.example\n'
    else
        printf 'Protocol version: TLSv1.3\nALPN protocol: h2\n'
    fi
}
kokoro_reality_cert_covers_host() { return 0; }
kokoro_reality_bad_redirect() { return 1; }
kokoro_reality_has_ocsp() { return 1; }
timeout() { shift; "$@"; }

kokoro_reality_network_init
[[ "$KOKORO_REALITY_SERVER_ASNS" == 64500 ]]
for address in 999.0.0.1 '::::' '1:2:3' '1:2:3:4:5:6:7:8:9' '2001::db8::1'; do
    if kokoro_reality_ip_literal "$address"; then
        echo "invalid IP accepted: $address" >&2; exit 1
    fi
done
[[ "$(kokoro_reality_target_ip match.example)" == 203.0.113.20 ]]
[[ "$(kokoro_reality_target_ip dual.example)" == 203.0.113.20 ]]
[[ "$(kokoro_reality_target_ip ipv6.example)" == 2001:db8::20 ]]
[[ "$(kokoro_reality_endpoint 2001:db8::20)" == '[2001:db8::20]:443' ]]
for host in foreign.example mixed.example moas.example unknown.example self.example; do
    if kokoro_reality_target_ip "$host" >/dev/null; then
        echo "unsafe target accepted: $host" >&2
        exit 1
    fi
done

# Exercise the scanner itself: a valid TLS host in another ASN must be rejected.
row="$(kokoro_reality_validate_one foreign.example)"
[[ "$row" == FAIL$'\t'* ]] || {
    echo "scanner accepted a foreign-ASN target: $row" >&2
    exit 1
}
[[ ! -e "$TMP/tls-calls" ]]
row="$(kokoro_reality_validate_one match.example)"
[[ "$row" == OK$'\t'* ]]
[[ "$(cut -f6 <<<"$row")" == 203.0.113.20 ]]
grep -q -- '-connect 203.0.113.20:443' "$TMP/tls-calls"
grep -q -- '-verify_hostname match.example -verify_return_error' "$TMP/tls-calls"

# Manual selection follows the same checks and pins the address tested.
kokoro_ensure_state
kokoro_reality_apply_host match.example >/dev/null
[[ "$(kokoro_cfg '.inbound.reality.dest')" == '203.0.113.20:443' ]]
[[ "$(kokoro_cfg '.inbound.reality.server_names[0]')" == match.example ]]
before="$(sha256sum "$KOKORO_CONFIG")"
if kokoro_reality_apply_host foreign.example >/dev/null 2>&1; then
    echo 'manual selection accepted a foreign-ASN target' >&2
    exit 1
fi
[[ "$(sha256sum "$KOKORO_CONFIG")" == "$before" ]]

# A service outage or nonliteral server address never permits unchecked selection.
if (KOKORO_PUBLIC_ADDRESS=203.0.113.50; kokoro_reality_network_init) 2>/dev/null; then
    echo 'unknown server ASN accepted' >&2; exit 1
fi
if (KOKORO_PUBLIC_ADDRESS=vps.example; kokoro_reality_network_init) 2>/dev/null; then
    echo 'hostname accepted as the server IP' >&2; exit 1
fi
kokoro_reality_provider_hosts | grep -qx 'www.provider.example'

# Ranking prefers latency over a higher compatibility score.
printf 'OK\t100\t200\tsame-asn\tslow.example\t203.0.113.20\nOK\t90\t10\tsame-asn\tmatch.example\t203.0.113.20\n' >"$TMP/ranked"
kokoro_reality_scan_pick "$TMP/ranked" 10 false >/dev/null
[[ "$(kokoro_cfg '.inbound.reality.server_names[0]')" == match.example ]]

# Manual onboarding retries rejected input instead of substituting a default.
source "$ROOT/lib/onboard.sh"
kokoro_onboard_reality_target false <<< $'foreign.example\nmatch.example' >"$TMP/onboard.log" 2>&1
[[ "$(kokoro_cfg '.inbound.reality.server_names[0]')" == match.example ]]
if kokoro_onboard_reality_target false <<< '' >/dev/null 2>&1; then
    echo 'empty onboarding input selected an unchecked target' >&2; exit 1
fi
kokoro_cfg_set '.inbound.mode' '"reality"'
kokoro_cfg_set '.inbound.reality.server_names' '["foreign.example"]'
if (kokoro_onboard_edge </dev/null) >"$TMP/unattended.log" 2>&1; then
    echo 'noninteractive onboarding accepted a foreign target' >&2; exit 1
fi
kokoro_cfg_set '.inbound.reality.server_names' '["match.example"]'
kokoro_onboard_edge </dev/null >/dev/null

# Run worker subprocesses too, using the actual ASN and TLS validation functions.
export -f curl getent openssl timeout
kokoro_reality_scan --domains match.example --apply >"$TMP/scan.log" 2>&1
grep -q 'same-asn' "$TMP/scan.log"
[[ "$(jq -r '.inbound.reality.dest' "$KOKORO_CONFIG")" == '203.0.113.20:443' ]]
cp "$KOKORO_CONFIG" "$TMP/saved-config"
getent() {
    [[ "$2" == 203.0.113.10 ]] || printf '203.0.113.30 STREAM foreign.example\n'
}
export -f getent
if kokoro_reality_scan --apply >"$TMP/empty.log" 2>&1; then
    echo 'all-foreign scan unexpectedly applied a target' >&2; exit 1
fi
grep -q 'no verified same-ASN target' "$TMP/empty.log"
cmp "$KOKORO_CONFIG" "$TMP/saved-config"
[[ -z "${KOKORO_REALITY_ASN_CACHE:-}" ]]
echo 'reality-asn-test OK'
