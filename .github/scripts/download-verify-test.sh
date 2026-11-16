#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="/tmp/kokoro-download-verify-test"
rm -rf "$OUT"
mkdir -p "$OUT"

export KOKORO_ROOT="$ROOT"
source "${ROOT}/lib/geodata.sh"

printf 'kokoro-test-zip\n' >"${OUT}/test.zip"
sha="$(sha256sum "${OUT}/test.zip" | awk '{print $1}')"

cat >"${OUT}/test.zip.dgst" <<EOF
MD5= unused
SHA2-256= ${sha}
EOF

kokoro_xray_verify_zip "${OUT}/test.zip" "$sha"
echo "checksum_ok OK"

if (kokoro_xray_verify_zip "${OUT}/test.zip" 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1); then
    echo "bad checksum unexpectedly passed" >&2
    exit 1
fi

echo "checksum_bad OK"

[[ "$(kokoro_xray_sha256 "$KOKORO_XRAY_VERSION" 64)" == "$KOKORO_XRAY_SHA256_AMD64" ]]
[[ "$(kokoro_xray_sha256 "$KOKORO_XRAY_VERSION" arm64-v8a)" == "$KOKORO_XRAY_SHA256_ARM64" ]]
echo "release_pins OK"
echo "download-verify-test OK"
