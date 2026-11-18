#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" KOKORO_ROOT="$ROOT" KOKORO_PUBLIC_ADDRESS=203.0.113.10
mkdir -p "$HOME/.kokoro-xray"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=direct.example \
    -addext 'subjectAltName=DNS:direct.example' \
    -keyout "$TMP/tls.key" -out "$TMP/tls.crt" >/dev/null 2>&1
jq --arg cert "$TMP/tls.crt" --arg key "$TMP/tls.key" '
    .role = "edge" | .inbound.transport = "raw" | .inbound.mode = "both"
    | .inbound.tls.domain = "direct.example" | .multinode.enabled = false
    | .inbound.hysteria.enabled = false | .inbound.vless_encryption.enabled = true
    | .paths.tls_cert = $cert | .paths.tls_key = $key
' "$ROOT/config.defaults.json" >"$HOME/.kokoro-xray/config.json"
cp "$ROOT/.github/fixtures/edge-secrets.json" "$HOME/.kokoro-xray/secrets.json"
source "$ROOT/lib/link.sh"
source "$ROOT/lib/caddy.sh"
source "$ROOT/lib/fallback.sh"
kokoro_ensure_state

for mode in reality tls both; do
    kokoro_cfg_set_str '.inbound.mode' "$mode"
    jq -n -f "$ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" \
        --slurpfile sec "$KOKORO_SECRETS" >"$TMP/$mode.json"
    jq -e 'all(.inbounds[];
        .streamSettings.network == "raw" and .settings.clients[0].flow == "xtls-rprx-vision"
        and .sniffing.routeOnly == true
        and (.streamSettings | has("xhttpSettings") | not))' "$TMP/$mode.json" >/dev/null
    if [[ "$mode" != tls ]]; then
        jq -e '.inbounds[] | select(.tag == "REALITY_RAW_IN")
            | .streamSettings.security == "reality" and (.settings | has("fallbacks") | not)' "$TMP/$mode.json" >/dev/null
        json="$(kokoro_link_show --json reality)"
        jq -e '.outbounds[0] | .streamSettings.network == "raw"
            and .settings.vnext[0].users[0].flow == "xtls-rprx-vision-udp443"' <<<"$json" >/dev/null
        [[ "$(kokoro_link_reality_url)" == *'type=tcp&flow=xtls-rprx-vision-udp443'* ]]
        printf '%s\n' "$json" >"$TMP/client-reality.json"
    fi
    if [[ "$mode" != reality ]]; then
        kokoro_caddy_needs_l4
        jq -e '.inbounds[] | select(.tag == "TLS_RAW_IN")
            | .streamSettings.security == "tls"
              and .settings.fallbacks[0].dest == "127.0.0.1:8080"
              and .settings.decryption == "none"
              and .streamSettings.tlsSettings.alpn == ["h2","http/1.1"]' "$TMP/$mode.json" >/dev/null
        json="$(kokoro_link_show --json tls)"
        jq -e '.outbounds[0] | .streamSettings.network == "raw"
            and .settings.vnext[0].users[0].flow == "xtls-rprx-vision-udp443"
            and .settings.vnext[0].address == "direct.example"
            and .settings.vnext[0].users[0].encryption == "none"
            and (.streamSettings | has("xhttpSettings") | not)' <<<"$json" >/dev/null
        [[ "$(kokoro_link_tls_url)" == *'type=tcp&flow=xtls-rprx-vision-udp443'* ]]
        printf '%s\n' "$json" >"$TMP/client-tls.json"
        jq -nr -f "$ROOT/lib/caddy.jq" --slurpfile cfg "$KOKORO_CONFIG" \
            --slurpfile sec "$KOKORO_SECRETS" >"$TMP/Caddyfile"
        grep -q '@rawtls tls sni direct.example' "$TMP/Caddyfile"
        grep -q 'proxy tcp/127.0.0.1:8444' "$TMP/Caddyfile"
        grep -q 'protocols h1 h2c' "$TMP/Caddyfile"
        grep -q 'disable_tlsalpn_challenge' "$TMP/Caddyfile"
        grep -q 'reverse_proxy 127.0.0.1:8081' "$TMP/Caddyfile"
        ! grep -q 'handle .*xhttp' "$TMP/Caddyfile"
        if [[ -n "${CADDY_BIN:-}" ]]; then "$CADDY_BIN" adapt --config "$TMP/Caddyfile" >/dev/null; fi
    fi
    if command -v xray >/dev/null 2>&1; then xray run -test -config "$TMP/$mode.json"; fi
done
if command -v xray >/dev/null 2>&1; then
    xray run -test -config "$TMP/client-reality.json"
    xray run -test -config "$TMP/client-tls.json"
fi

unit="$(kokoro_fallback_unit_content)"
[[ "$unit" == *'--publish=127.0.0.1:8081:8080'* ]]
[[ "$unit" == *'--user=65534:82 --cap-drop=all --security-opt=no-new-privileges'* ]]
[[ "$unit" == *'--read-only '* && "$unit" == *'--memory=192m'* ]]
[[ "$unit" == *'--image-volume=ignore'* && "$unit" == *'size=16m'* ]]
[[ "$unit" == *'ghcr.io/privatebin/fs@sha256:'* ]]
[[ "$unit" != *'--privileged'* && "$unit" != *'/var/run/'* ]]
if [[ -x /usr/bin/podman ]] && command -v systemd-analyze >/dev/null 2>&1; then
    printf '%s\n' "$unit" >"$TMP/kokoro-fallback.service"
    kokoro_verify_systemd_unit "$TMP/kokoro-fallback.service"
fi
grep -qx 'discussion = false' "$ROOT/templates/privatebin/conf.php"
grep -qx 'fileupload = false' "$ROOT/templates/privatebin/conf.php"

# RAW and HY2 coexist, including a shared direct TLS domain.
kokoro_sec_set_str '.inbound.hysteria.auth' test-auth
kokoro_sec_set_str '.inbound.hysteria.obfs_password' test-obfs
kokoro_cfg_set '.inbound.hysteria.enabled' true
kokoro_cfg_set_str '.paths.hysteria_cert' "$TMP/tls.crt"
kokoro_cfg_set_str '.paths.hysteria_key' "$TMP/tls.key"
for domain in direct.example hy.example; do
    kokoro_cfg_set_str '.inbound.hysteria.domain' "$domain"
    jq -nr -f "$ROOT/lib/caddy.jq" --slurpfile cfg "$KOKORO_CONFIG" \
        --slurpfile sec "$KOKORO_SECRETS" >"$TMP/Caddyfile.hy"
    [[ "$(grep -c '^direct.example {' "$TMP/Caddyfile.hy")" == 1 ]]
    if [[ -n "${CADDY_BIN:-}" ]]; then "$CADDY_BIN" adapt --config "$TMP/Caddyfile.hy" >/dev/null; fi
done
jq -n -f "$ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" \
    --slurpfile sec "$KOKORO_SECRETS" >"$TMP/raw-hy.json"
if command -v xray >/dev/null 2>&1; then xray run -test -config "$TMP/raw-hy.json"; fi
kokoro_cfg_set '.inbound.hysteria.enabled' false

# Old state stays XHTTP when defaults are merged; RAW is an explicit selection.
kokoro_cfg_set '.inbound.transport' '"xhttp"'
json="$(kokoro_link_show --json reality)"
jq -e '.outbounds[0].streamSettings.network == "xhttp"' <<<"$json" >/dev/null

# A missing required frontend must not be reported as a successful validation.
source "$ROOT/lib/validate.sh"
export KOKORO_TEST_PATH_ROOT="$TMP"
mkdir -p "$TMP/geo"
touch "$TMP/geo/geoip.dat" "$TMP/geo/geosite.dat"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/fake-xray"
chmod +x "$TMP/fake-xray"
kokoro_cfg_set_str '.paths.xray_bin' "$TMP/fake-xray"
kokoro_cfg_set_str '.paths.xray_config' "$TMP/both.json"
kokoro_cfg_set_str '.paths.geo_dir' "$TMP/geo"
kokoro_cfg_set_str '.paths.caddy_bin' "$TMP/missing-caddy"
kokoro_cfg_set_str '.paths.caddyfile' "$TMP/Caddyfile"
if kokoro_validate >"$TMP/validate.log" 2>&1; then
    echo 'missing required Caddy binary passed validation' >&2; exit 1
fi
grep -q 'caddy binary not found' "$TMP/validate.log"
echo 'raw-vision-test OK'
