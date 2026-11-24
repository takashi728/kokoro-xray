#!/usr/bin/env bash
# Local Xray + Caddy L4 test. The extra HTTPS listener emulates the CDN edge.
set -euo pipefail

: "${CADDY_BIN:?set CADDY_BIN to Caddy with caddy-l4}"
XRAY_BIN="${XRAY_BIN:-$(command -v xray)}"
ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
pids=()
cleanup() {
    local status=$? pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    if (( status != 0 )); then tail -n 20 "$tmp"/*.log >&2 || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
export HOME="$tmp" KOKORO_ROOT="$ROOT" XDG_DATA_HOME="$tmp/data" XDG_CONFIG_HOME="$tmp/config"
source "$ROOT/lib/common.sh"
kokoro_ensure_state
kokoro_cfg_set_str '.role' edge
kokoro_cfg_set '.inbound.xhttp_split' true
kokoro_cfg_set_str '.inbound.tls.cdn_domain' cdn.example
kokoro_cfg_set_str '.inbound.reality.dest' 127.0.0.1:16443
kokoro_cfg_set '.inbound.reality.server_names' '["cover.example"]'
cp "$ROOT/.github/fixtures/edge-secrets.json" "$KOKORO_SECRETS"
chmod 600 "$KOKORO_SECRETS"
reality_keys="$("$XRAY_BIN" x25519)"
kokoro_sec_set_str '.inbound.reality.private_key' "$(awk '/^PrivateKey:/ {print $2}' <<<"$reality_keys")"
kokoro_sec_set_str '.inbound.reality.public_key' "$(awk -F': *' '/^Password/ {print $2}' <<<"$reality_keys")"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=cdn.example \
    -addext 'subjectAltName=DNS:cdn.example,DNS:cover.example' \
    -keyout "$tmp/tls.key" -out "$tmp/tls.crt" >/dev/null 2>&1
jq -n -f "$ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" \
    --slurpfile sec "$KOKORO_SECRETS" | jq '
    .inbounds[0].port = 18443
    | .inbounds[0].settings.fallbacks[0].dest = "127.0.0.1:18444"
    | .inbounds[1].port = 18444
    | .routing.rules = [{type:"field",network:"tcp,udp",outboundTag:"DIRECT"}]
    | (.outbounds[] | select(.tag == "DIRECT")).settings.finalRules =
        [{action:"allow",ip:["127.0.0.1/32"]}]
' >"$tmp/server.json"
jq -nr -f "$ROOT/lib/caddy.jq" --slurpfile cfg "$KOKORO_CONFIG" \
    --slurpfile sec "$KOKORO_SECRETS" >"$tmp/Caddyfile"
"$CADDY_BIN" adapt --config <(printf '%s\n' "$(cat "$tmp/Caddyfile")"
    printf 'https://cdn.example:15443 {
        bind 127.0.0.1
        tls %s/tls.crt %s/tls.key
        reverse_proxy https://127.0.0.1:14443 {
            header_up Host cdn.example
            transport http {
                tls_server_name cdn.example
                tls_trust_pool file %s/tls.crt
            }
        }
    }
    https://cover.example:16443 {
        bind 127.0.0.1
        tls %s/tls.crt %s/tls.key
        respond "cover"
    }\n' "$tmp" "$tmp" "$tmp" "$tmp" "$tmp"
) --adapter caddyfile | jq '
    walk(if type == "string" then
        if . == "tcp/127.0.0.1:8443" then "tcp/127.0.0.1:18443"
        elif . == "127.0.0.1:8444" then "127.0.0.1:18444"
        else . end else . end)
    | .admin.disabled = true
    | .apps.http.grace_period = 1000000000
    | .apps.tls.automation.policies = []
    | .apps.http.servers |= map_values(
        .automatic_https.disable = true
        | if .listen | index(":443") then .tls_connection_policies //= [{}] else . end
        | .listen |= map(
            if . == ":443" then ("127.0.0.1:14443","[::1]:14443")
            elif . == ":80" then "127.0.0.1:18000"
            else . end))
' >"$tmp/caddy.json"

openssl rand -out "$tmp/payload" 1048576
node -e '
    require("node:http").createServer((req, res) => {
        if (req.method === "POST") req.pipe(res);
        else res.end("ready");
    }).listen(18081, "127.0.0.1");
' >"$tmp/echo.log" 2>&1 &
pids+=("$!")
"$XRAY_BIN" run -config "$tmp/server.json" >"$tmp/server.log" 2>&1 &
pids+=("$!")
"$CADDY_BIN" run --config "$tmp/caddy.json" >"$tmp/caddy.log" 2>&1 &
pids+=("$!")

probe() {
    curl -fsS --noproxy '*' --max-time 2 --cacert "$tmp/tls.crt" "$@"
}
for i in {1..30}; do
    if probe --resolve cdn.example:15443:127.0.0.1 https://cdn.example:15443/ >/dev/null 2>&1; then break; fi
    sleep 0.2
done
[[ "$(probe --http3-only --resolve cdn.example:15443:127.0.0.1 https://cdn.example:15443/)" == ok ]]
[[ "$(probe --http2 --resolve 'cover.example:14443:[::1]' https://cover.example:14443/)" == cover ]]

run_profile() {
    local wanted="$1" client
    shift
    bash "$ROOT/kokoro-xray.sh" link --json xhttp-split "$@" | jq --arg cert "$tmp/tls.crt" '
        def local_stream:
            if .security == "tls" then
                .tlsSettings.certificates = [{certificateFile:$cert,usage:"verify"}]
            else . end;
        def port_for($security): if $security == "tls" then 15443 else 14443 end;
        .inbounds = [.inbounds[0] | .port = 19108]
        | .log.loglevel = "info"
        | .outbounds[0] |= (
            .streamSettings.security as $security
            | .settings.vnext[0].port = port_for($security)
            | .streamSettings |= (local_stream |
                if .xhttpSettings.downloadSettings then
                    .xhttpSettings.downloadSettings |= (local_stream | .port = port_for(.security))
                else . end)
        )
        | .routing.rules = [.routing.rules[-1]]
    ' >"$tmp/client.json"
    "$XRAY_BIN" run -config "$tmp/client.json" >"$tmp/client.log" 2>&1 &
    client=$!
    pids+=("$client")
    for i in {1..30}; do
        if grep -q 'started' "$tmp/client.log"; then break; fi
        kill -0 "$client"
        sleep 0.1
    done
    curl --noproxy '' --socks5 127.0.0.1:19108 -fsS --max-time 12 \
        --data-binary @"$tmp/payload" http://127.0.0.1:18081/ >"$tmp/received"
    cmp "$tmp/payload" "$tmp/received"
    grep -q "$wanted" "$tmp/client.log"
    kill "$client"
    wait "$client" 2>/dev/null || true
    unset 'pids[-1]'
    printf 'xhttp-split-integration: payload verified for %s\n' "$*"
}

run_profile 'HTTP version 2' cdn-h2=127.0.0.1
run_profile 'HTTP version 3' cdn-h3=127.0.0.1
run_profile 'stream-down, HTTP version 3' cdn-h2=127.0.0.1 cdn-h3=127.0.0.1
run_profile 'mode stream-one, HTTP version 2' reality=::1
run_profile 'stream-down, HTTP version 2' reality=127.0.0.1 reality=::1
run_profile 'stream-down, HTTP version 2' reality=::1 reality=127.0.0.1
run_profile 'stream-down, HTTP version 2' cdn-h2=127.0.0.1 reality=::1
run_profile 'stream-down, HTTP version 2' reality=::1 cdn-h2=127.0.0.1
run_profile 'stream-down, HTTP version 2' cdn-h3=127.0.0.1 reality=::1
run_profile 'stream-down, HTTP version 3' reality=::1 cdn-h3=127.0.0.1
