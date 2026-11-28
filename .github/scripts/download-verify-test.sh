#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf -- "$OUT"' EXIT

export KOKORO_ROOT="$ROOT"
source "${ROOT}/lib/geodata.sh"
source "${ROOT}/lib/caddy.sh"

printf 'kokoro-test-zip\n' >"${OUT}/test.zip"
fixture_sha="$(sha256sum "${OUT}/test.zip" | awk '{print $1}')"

cat >"${OUT}/test.zip.dgst" <<EOF
MD5= unused
SHA2-256= ${fixture_sha}
EOF

kokoro_xray_verify_zip "${OUT}/test.zip" "$fixture_sha"
echo "checksum_ok OK"

if (kokoro_xray_verify_zip "${OUT}/test.zip" 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1); then
    echo "bad checksum unexpectedly passed" >&2
    exit 1
fi

echo "checksum_bad OK"

[[ "$(kokoro_xray_sha256 "$KOKORO_XRAY_VERSION" 64)" == "$KOKORO_XRAY_SHA256_AMD64" ]]
[[ "$(kokoro_xray_sha256 "$KOKORO_XRAY_VERSION" arm64-v8a)" == "$KOKORO_XRAY_SHA256_ARM64" ]]
echo "release_pins OK"

fail() { echo "$*" >&2; exit 1; }

curl() {
    local proto='' redir='' url='' output=''
    while (( $# )); do
        case "$1" in
            --proto) proto="$2"; shift ;;
            --proto-redir) redir="$2"; shift ;;
            -o) output="$2"; shift ;;
            *://*) url="$1" ;;
        esac
        shift
    done
    printf '%s %s %s\n' "$proto" "$redir" "$url" >>"$OUT/requests"
    [[ -n "$output" ]] || return 1
    cp "$fixture" "$output"
}

assert_request() {
    [[ "$(<"$OUT/requests")" == "=https =https $1" ]] || fail "unexpected curl request(s) for $1"
    : >"$OUT/requests"
}

kokoro_caddy_needs_l4() { return 0; }
kokoro_go_arch() { echo "$test_arch"; }
version=v2.11.9
KOKORO_CADDY_L4_VERSION=v0.1.3
release="caddy-l4-${version}-${KOKORO_CADDY_L4_VERSION}"
fixture="$OUT/caddy.tgz"
printf 'fixture executable\n' >"$OUT/caddy"
tar -C "$OUT" -czf "$fixture" caddy
printf 'previous binary\n' >"$OUT/staged"
: >"$OUT/requests"

for test_arch in amd64 arm64; do
    case "$test_arch" in
        amd64) pin=ea47e309445d507be7101e1a3500b75d3962aa9aa64d208c369b46e83db4a512 ;;
        arm64) pin=281ba043991d4b1f6ef4e7f05dbab3b3fe0eab7c49afc8751fffd6af939ae334 ;;
    esac
    [[ "$(kokoro_caddy_l4_sha256 "${version}-${KOKORO_CADDY_L4_VERSION}" "$test_arch")" == "$pin" ]] ||
        fail "wrong release pin for $test_arch"
    if kokoro_caddy_download "$version" "$OUT/staged"; then
        fail "accepted a Caddy archive with the wrong digest on $test_arch"
    fi
    assert_request "https://github.com/takashi728/kokoro-xray/releases/download/${release}/caddy-linux-${test_arch}.tar.gz"
    [[ "$(<"$OUT/staged")" == 'previous binary' ]] || fail "overwrote staged binary on mismatch"
done

test_arch=amd64
if kokoro_caddy_download v2.11.8 "$OUT/staged" ||
    KOKORO_CADDY_L4_VERSION=v0.1.4 kokoro_caddy_download "$version" "$OUT/staged" ||
    test_arch=riscv64 kokoro_caddy_download "$version" "$OUT/staged"; then
    fail 'accepted an unpinned release or architecture'
fi
[[ ! -s "$OUT/requests" ]] || fail 'fetched before checking for a pin'
(
    kokoro_caddy_l4_sha256() { sha256sum "$fixture" | cut -d ' ' -f1; }
    kokoro_caddy_download "$version" "$OUT/staged"
)
assert_request "https://github.com/takashi728/kokoro-xray/releases/download/${release}/caddy-linux-amd64.tar.gz"
cmp "$OUT/caddy" "$OUT/staged"
echo "caddy_l4_download OK"

fixture="$OUT/test.zip"
(
    kokoro_go_sha256() { echo "$fixture_sha"; }
    kokoro_go_download "$KOKORO_GO_VERSION" amd64 "$OUT"
)
assert_request "https://go.dev/dl/go${KOKORO_GO_VERSION}.linux-amd64.tar.gz"
kokoro_xray_release_arch() { echo 64; }
if kokoro_xray_download_release_zip "$OUT" >"$OUT/result" 2>/dev/null; then
    fail 'returned an unverified Xray archive'
fi
assert_request "https://github.com/XTLS/Xray-core/releases/download/${KOKORO_XRAY_VERSION}/Xray-linux-64.zip"
[[ ! -s "$OUT/result" ]] || fail 'printed unverified Xray archive name'
echo "https_downloads OK"
echo "download-verify-test OK"
