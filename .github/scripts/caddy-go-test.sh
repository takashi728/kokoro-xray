#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="/tmp/kokoro-caddy-go-test"
rm -rf "$TMP"
mkdir -p "$TMP/old" "$TMP/new"

export KOKORO_ROOT="$ROOT"
source "${ROOT}/lib/caddy.sh"

kokoro_version_ge 1.26.9 1.26.9
kokoro_version_ge 1.27.4 1.26.9
if kokoro_version_ge 1.26.8 1.26.9; then
    echo "old Go version unexpectedly passed" >&2
    exit 1
fi
echo "version_compare OK"

cat >"${TMP}/old/go" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.20.14 linux/amd64"
EOF
chmod +x "${TMP}/old/go"

cat >"${TMP}/new/go" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.26.11 linux/amd64"
EOF
chmod +x "${TMP}/new/go"

kokoro_go_install_official() {
    KOKORO_CADDY_GO_BIN="${TMP}/new/go"
}

PATH="${TMP}/old:${PATH}" kokoro_go_for_caddy >/dev/null
[[ "$KOKORO_CADDY_GO_BIN" == "${TMP}/new/go" ]]
echo "fallback_go OK"

rm -rf "$TMP"
echo "caddy-go-test OK"
