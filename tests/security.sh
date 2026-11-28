#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

state="${TMP}/.kokoro-xray"
units="${TMP}/units"
install -d -m 700 "$state" "$units"
cp "$ROOT/config.defaults.json" "${state}/config.json"
cp "$ROOT/secrets.defaults.json" "${state}/secrets.json"
chmod 644 "${state}/config.json"
chmod 600 "${state}/secrets.json"

source_common() {
    HOME="$TMP" KOKORO_ROOT="$ROOT" KOKORO_TEST_SYSTEMD_UNIT_DIR="$units" bash -c '
        set -euo pipefail
        source "${KOKORO_ROOT}/lib/common.sh"
        source "${KOKORO_ROOT}/lib/xray.sh"
        source "${KOKORO_ROOT}/lib/preflight.sh"
        "$@"
    ' _ "$@"
}

assert_safe_path() {
    source_common kokoro_require_safe_path "$1" "$2"
}

assert_unsafe_path() {
    local label="$1" path="$2"
    if source_common kokoro_require_safe_path "$label" "$path" >/dev/null 2>&1; then
        echo "unsafe path accepted: ${path}" >&2
        exit 1
    fi
}

assert_safe_path xray /usr/local/bin/xray
assert_unsafe_path xray $'/usr/local/bin/xray\nExecStart=/bin/sh'
assert_unsafe_path xray '/usr/local/bin/xray run'
assert_unsafe_path xray '/usr/local/bin/xray%0AExecStart=/bin/sh'
assert_unsafe_path xray '/usr/local/bin/../bin/xray'
assert_unsafe_path xray 'relative/xray'

injected="/usr/local/bin/xray
ExecStart=/bin/sh -c 'touch /tmp/kokoro-unit-pwn' #"
assert_unsafe_path xray "$injected"

write_manifest_config() { # xray-bin caddy-bin
    jq --arg xray "$1" --arg caddy "$2" '
        .paths.xray_bin = $xray | .paths.caddy_bin = $caddy
    ' "${state}/config.json" >"${state}/config.next"
    mv "${state}/config.next" "${state}/config.json"
}

# A non-canonical path must be rejected before its executable is run.
tainted_bin="${TMP}/tainted-xray"
cat >"$tainted_bin" <<EOF
#!/usr/bin/env bash
touch "${TMP}/tainted-executed"
EOF
chmod +x "$tainted_bin"
jq --arg bin "$tainted_bin" '.paths.xray_bin = $bin' \
    "${state}/config.json" >"${state}/config.next"
mv "${state}/config.next" "${state}/config.json"
if HOME="$TMP" KOKORO_ROOT="$ROOT" bash -c '
    source "${KOKORO_ROOT}/lib/keys.sh"
    kokoro_gen_uuid
' >/dev/null 2>&1; then
    echo "non-canonical Xray path was accepted" >&2
    exit 1
fi
[[ ! -e "${TMP}/tainted-executed" ]]

write_manifest_config "$injected" "/usr/local/bin/caddy"
source_common kokoro_validate_service_paths >/dev/null 2>&1 && {
    echo "injected Xray path passed service validation" >&2
    exit 1
}

cert_root="${TMP}/cert-root"
install -d -m 700 "${cert_root}/issuer/example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
    -keyout "${cert_root}/issuer/example.com/example.com.key" \
    -out "${cert_root}/issuer/example.com/example.com.crt" >/dev/null 2>&1
jq --arg cert "${cert_root}/issuer/example.com/example.com.crt" \
   --arg key "${cert_root}/issuer/example.com/example.com.key" '
    .paths.xray_bin = "/usr/local/bin/xray"
    | .paths.caddy_bin = "/usr/local/bin/caddy"
    | .paths.hysteria_cert = $cert
    | .paths.hysteria_key = $key
    | .inbound.hysteria.enabled = true
' "${state}/config.json" >"${state}/config.next"
mv "${state}/config.next" "${state}/config.json"
HOME="$TMP" KOKORO_ROOT="$ROOT" KOKORO_TEST_HYSTERIA_CERT_ROOT="$cert_root" bash -c '
    set -euo pipefail
    source "${KOKORO_ROOT}/lib/common.sh"
    kokoro_require_hysteria_file ".paths.hysteria_cert" ".crt"
    kokoro_require_hysteria_file ".paths.hysteria_key" ".key"
'

cp "${cert_root}/issuer/example.com/example.com.crt" "${TMP}/escaped.crt"
jq --arg cert "${TMP}/escaped.crt" '.paths.hysteria_cert = $cert' \
    "${state}/config.json" >"${state}/config.next"
mv "${state}/config.next" "${state}/config.json"
if HOME="$TMP" KOKORO_ROOT="$ROOT" KOKORO_TEST_HYSTERIA_CERT_ROOT="$cert_root" bash -c '
    source "${KOKORO_ROOT}/lib/common.sh"
    kokoro_require_hysteria_file ".paths.hysteria_cert" ".crt"
' >/dev/null 2>&1; then
    echo "certificate path escaped the monitored root" >&2
    exit 1
fi

source "$ROOT/lib/reality-scan.sh"
cert_match() { # host expected
    local host="$1" expected="$2" got
    got="$(
        TEST_SAN="$expected" bash -c '
            source "$1/lib/reality-scan.sh"
            openssl() { printf "X509v3 Subject Alternative Name:\n    DNS:%s\n" "$TEST_SAN"; }
            timeout() { shift; "$@"; }
            kokoro_reality_cert_covers_host "$2" && echo yes || echo no
        ' _ "$ROOT" "$host"
    )"
    [[ "$got" == "yes" ]]
}

cert_match example.com "example.com"
cert_match www.example.com "*.example.com"
if cert_match example.com "*.example.com"; then
    echo "wildcard incorrectly covered apex" >&2
    exit 1
fi
if cert_match badexample.com "*.example.com"; then
    echo "wildcard incorrectly covered suffix collision" >&2
    exit 1
fi
if cert_match www.example.com "\.example.com"; then
    echo "substring SAN incorrectly matched" >&2
    exit 1
fi

jq '.role = "edge" | .inbound.tls.cdn_domain = "edge.example.com"
    | .inbound.vless_encryption.enabled = false' "$ROOT/config.defaults.json" >"$TMP/valid-cfg"
cp "$ROOT/.github/fixtures/edge-secrets.json" "$TMP/valid-sec"
caddy_fixture() {
    jq -nr -f "$ROOT/lib/caddy.jq" --slurpfile cfg "$state/config.json" \
        --slurpfile sec "$state/secrets.json" >/dev/null
}
cp "$TMP/valid-cfg" "$state/config.json"
cp "$TMP/valid-sec" "$state/secrets.json"
caddy_fixture
source_common kokoro_preflight
for field in '.inbound.reality.server_names[1]' '.inbound.tls.cdn_domain' \
             '.inbound.xhttp_path' '.inbound.tls.acme_email' '.inbound.hysteria.acme_email'; do
    for invalid in $'valid.example\n' 'bad value' 'bad{value}'; do
        cp "$TMP/valid-cfg" "$state/config.json"
        cp "$TMP/valid-sec" "$state/secrets.json"
        if [[ "$field" == .inbound.xhttp_path ]]; then file=secrets; else file=config; fi
        jq --arg value "$invalid" "$field = \$value" "$state/$file.json" >"$TMP/mutated"
        cat "$TMP/mutated" >"$state/$file.json"
        if caddy_fixture 2>/dev/null || source_common kokoro_preflight >/dev/null 2>&1; then
            echo "accepted malformed $field" >&2
            exit 1
        fi
    done
done

cp "$TMP/valid-cfg" "$state/config.json"
source_common kokoro_xray_unit_content >"$units/xray.service"
HOME="$TMP" bash -c 'source "$1/lib/caddy.sh"; kokoro_caddy_unit_content' _ "$ROOT" >"$units/caddy.service"
for service in xray caddy; do
    unit="$units/$service.service"
    grep -Fxq "User=kokoro-$service" "$unit"
    grep -Fxq 'NoNewPrivileges=true' "$unit"
    grep -Fxq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$unit"
    grep -Fxq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$unit"
    sed -i -E 's@/usr/local/(libexec/kokoro-xray-input|bin/(caddy|xray))@/usr/bin/true@g' "$unit"
    source_common kokoro_verify_systemd_unit "$unit"
done
grep -Fxq 'StandardInput=file:/etc/caddy/Caddyfile' "$units/caddy.service"

(
    source "$ROOT/lib/xray-input.sh"
    cert="$cert_root/issuer/example.com/example.com.crt"
    key="$cert_root/issuer/example.com/example.com.key"
    jq -n --arg cert "$cert" --arg key "$key" '{
        inbounds:[{protocol:"http", port:18242, streamSettings:{security:"tls",
            tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}}],
        outbounds:[{protocol:"freedom"}]}' >"$TMP/xray-input.json"
    prepare_input "$TMP/xray-input.json" "$cert_root" >"$TMP/prepared.json"
    jq -e '.inbounds[0].streamSettings.tlsSettings.certificates[0] |
        (.certificate[0] == "-----BEGIN CERTIFICATE-----") and
        (.key[0] | startswith("-----BEGIN ")) and (has("keyFile") | not)' "$TMP/prepared.json" >/dev/null
    if command -v xray >/dev/null; then xray run -test -config "$TMP/prepared.json" >/dev/null; fi
    jq --arg path "$TMP/escaped.crt" \
        '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile=$path' \
        "$TMP/xray-input.json" >"$TMP/invalid.json"
    if (prepare_input "$TMP/invalid.json" "$cert_root") >/dev/null 2>&1; then exit 1; fi
)
echo "security-test OK"
