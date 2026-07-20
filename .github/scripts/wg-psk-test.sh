#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp_home="$(mktemp -d)"
state="${tmp_home}/.kokoro-xray"
fake_bin="${tmp_home}/bin"
install -d -m 700 "$state" "$fake_bin"

cat >"${fake_bin}/wg" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    genpsk) printf '%s\n' 'XSU70MSxWYuaI7OGzl2BE2gN46aI4jHSBwtBRbp28yY=' ;;
    *) exit 2 ;;
esac
EOF
chmod +x "${fake_bin}/wg"

cp "${ROOT}/config.defaults.json" "${state}/config.json"
cp "${ROOT}/secrets.defaults.json" "${state}/secrets.json"
jq '.role = "exit"' "${state}/config.json" >"${state}/config.tmp"
mv "${state}/config.tmp" "${state}/config.json"

HOME="$tmp_home" KOKORO_ROOT="$ROOT" PATH="${fake_bin}:${PATH}" bash <<'SCRIPT'
set -euo pipefail
source "${KOKORO_ROOT}/lib/keys.sh"
kokoro_ensure_wg_preshared_key
[[ "$(kokoro_sec '.multinode.wg_preshared_key')" == "XSU70MSxWYuaI7OGzl2BE2gN46aI4jHSBwtBRbp28yY=" ]]
kokoro_ensure_wg_preshared_key
[[ "$(kokoro_sec '.multinode.wg_preshared_key')" == "XSU70MSxWYuaI7OGzl2BE2gN46aI4jHSBwtBRbp28yY=" ]]
SCRIPT

rm -rf "$tmp_home"
echo "wg-psk-test OK"
