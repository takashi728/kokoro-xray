#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" KOKORO_ROOT="$ROOT" KOKORO_TEST_PATH_ROOT="$TMP"
export KOKORO_TEST_HYSTERIA_CERT_ROOT="$TMP/certificates"
mkdir -p "$HOME/.kokoro-xray" "$TMP/certificates/issuer/direct.example"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=direct.example \
    -keyout "$TMP/certificates/issuer/direct.example/direct.example.key" \
    -out "$TMP/certificates/issuer/direct.example/direct.example.crt" >/dev/null 2>&1
jq --arg bin "$TMP/caddy" --arg file "$TMP/Caddyfile" --arg xray "$TMP/xray.json" '
    .role = "edge" | .inbound.transport = "raw" | .inbound.mode = "tls"
    | .inbound.tls.domain = "direct.example"
    | .paths.caddy_bin = $bin | .paths.caddyfile = $file | .paths.xray_config = $xray
' "$ROOT/config.defaults.json" >"$HOME/.kokoro-xray/config.json"
cp "$ROOT/secrets.defaults.json" "$HOME/.kokoro-xray/secrets.json"
printf '#!/usr/bin/env bash\n[[ "${FAIL_VALIDATE:-}" != yes ]]\n' >"$TMP/caddy"
chmod +x "$TMP/caddy"
printf 'old-caddy-config\n' >"$TMP/Caddyfile"
printf '{"inbounds":[{"protocol":"vless","port":443,"listen":"0.0.0.0"}]}\n' >"$TMP/xray.json"

run_prepare() (
    set -euo pipefail
    source "$ROOT/lib/caddy.sh"
    kokoro_ensure_state
    kokoro_render_caddy() { printf 'temporary-bootstrap\n' >"$TMP/Caddyfile"; }
    install() {
        [[ "$*" == '-d -m 700 /var/lib/kokoro-caddy' ]] || command install "$@"
    }
    stat() {
        if [[ "$1" == -c && "$2" == '%u' ]]; then printf '0\n'
        else command stat "$@"; fi
    }
    systemctl() {
        printf '%s\n' "$*" >>"$TMP/services.log"
        if [[ "$1" == is-active ]]; then [[ "${!#}" == xray ]]
        else return 0; fi
    }
    kokoro_caddy_prepare_certificate direct.example tls
)

run_prepare >/dev/null
[[ "$(cat "$TMP/Caddyfile")" == old-caddy-config ]]
[[ "$(jq -r '.paths.tls_cert' "$HOME/.kokoro-xray/config.json")" == "$TMP/certificates/issuer/direct.example/direct.example.crt" ]]
grep -qx 'stop xray' "$TMP/services.log"
grep -qx 'restart xray' "$TMP/services.log"
stop_line="$(awk '$0 == "stop xray" {print NR; exit}' "$TMP/services.log")"
caddy_line="$(awk '$0 == "restart caddy" {print NR; exit}' "$TMP/services.log")"
[[ "$stop_line" -lt "$caddy_line" ]]

if FAIL_VALIDATE=yes run_prepare >/dev/null 2>&1; then
    echo 'invalid bootstrap unexpectedly succeeded' >&2; exit 1
fi
[[ "$(cat "$TMP/Caddyfile")" == old-caddy-config ]]

rm "$TMP/Caddyfile"
run_prepare >/dev/null
[[ ! -e "$TMP/Caddyfile" ]]
echo 'certificate-bootstrap-test OK'
