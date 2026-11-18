#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export KOKORO_ROOT="$ROOT" HOME="$TMP"
export KOKORO_PUBLIC_ADDRESS=203.0.113.10
source "$ROOT/lib/reality-scan.sh"
export KOKORO_REALITY_SERVER_IP=203.0.113.10 KOKORO_REALITY_SERVER_ASNS=64500

getent() {
    case "$2" in
        edge.example) printf '104.16.123.96 STREAM edge.example\n' ;;
        edge6.example) printf '2606:4700::6810:7b60 STREAM edge6.example\n' ;;
        mixed.example) printf '203.0.113.20 STREAM mixed.example\n104.16.123.96 STREAM mixed.example\n' ;;
        *) printf '203.0.113.20 STREAM %s\n' "$2" ;;
    esac
}
curl() {
    local arg resource=""
    for arg in "$@"; do
        [[ "$arg" == resource=* ]] && resource="${arg#resource=}"
    done
    if [[ "$*" == *network-info* ]]; then
        printf '{"status":"ok","data":{"asns":[64500]}}'
    elif [[ "$*" == *dns-chain* ]]; then
        case "$resource" in
            cname.example) printf '{"status":"ok","data":{"forward_nodes":{"cname.example":["customer.fastly.net"],"customer.fastly.net":["203.0.113.20"]}}}' ;;
            nested.example) printf '{"status":"ok","data":{"forward_nodes":{"nested.example":["origin.example"],"origin.example":["x.cloudfront.net"],"x.cloudfront.net":["203.0.113.20"]}}}' ;;
            failure.example) return 1 ;;
            malformed.example) printf '{"status":"ok","data":{"forward_nodes":null}}' ;;
            empty.example) printf '{"status":"ok","data":{"forward_nodes":{}}}' ;;
            split-view.example) printf '{"status":"ok","data":{"forward_nodes":{"split-view.example":["203.0.113.21"]}}}' ;;
            lookalike.example) printf '{"status":"ok","data":{"forward_nodes":{"lookalike.example":["notfastly.net"],"notfastly.net":["203.0.113.20"]},"authoritative_nameservers":["ns.cloudflare.com"]}}' ;;
            *) jq -cn --arg host "$resource" '{status:"ok",data:{forward_nodes:{($host):["203.0.113.20"]}}}' ;;
        esac
    else
        printf 'HTTP/2 200\r\nserver: cloudflare\r\ncf-ray: fixture\r\n\r\n'
    fi
}
timeout() { shift; "$@"; }

# The old ASN-only selector accepts this CDN edge because both ASNs match.
if kokoro_reality_target_ip edge.example >/dev/null; then
    echo 'same-ASN CDN edge accepted' >&2
    exit 1
fi
for host in edge6.example mixed.example cname.example nested.example failure.example malformed.example empty.example split-view.example; do
    if kokoro_reality_target_ip "$host" >/dev/null 2>&1; then
        echo "unsafe or unchecked CDN classification accepted: $host" >&2; exit 1
    fi
done
[[ "$(kokoro_reality_target_ip direct.example)" == 203.0.113.20 ]]
[[ "$(kokoro_reality_target_ip lookalike.example)" == 203.0.113.20 ]]

# A header signal can reject an edge missing from the address/suffix lists.
if kokoro_reality_bad_redirect direct.example 203.0.113.20; then
    echo 'unexpected redirect result' >&2; exit 1
else
    [[ "$?" == 3 ]]
fi
if kokoro_reality_cdn_headers_detected $'HTTP/2 200\nserver: nginx\nx-cache: HIT'; then
    echo 'generic origin cache misclassified as CDN' >&2; exit 1
fi

# Manual selection and the full scanner must not bypass edge screening.
kokoro_ensure_state
before="$(sha256sum "$KOKORO_CONFIG")"
if kokoro_reality_apply_host edge.example >/dev/null 2>&1; then
    echo 'manual selection accepted CDN target' >&2; exit 1
fi
[[ "$(sha256sum "$KOKORO_CONFIG")" == "$before" ]]
row="$(kokoro_reality_validate_one edge.example)"
[[ "$row" == *$'\tcdn-or-unverified\t'* ]]
openssl() { printf 'Protocol version: TLSv1.3\nALPN protocol: h2\n'; }
kokoro_reality_cert_covers_host() { return 0; }
row="$(kokoro_reality_validate_one direct.example)"
[[ "$row" == *$'\tcdn-header\t'* ]]

mkdir -p "$TMP/bad-data/data"
printf '{}\n' >"$TMP/bad-data/data/reality-cdn.json"
if KOKORO_ROOT="$TMP/bad-data" kokoro_reality_target_ip direct.example >/dev/null 2>&1; then
    echo 'invalid classification dataset accepted' >&2; exit 1
fi

# Missing/malformed classification data must fail closed, including grep errors.
grepcidr() { return 2; }
if kokoro_reality_target_ip direct.example >/dev/null 2>&1; then
    echo 'CIDR checker failure accepted' >&2; exit 1
fi
echo 'reality-cdn-test OK'
