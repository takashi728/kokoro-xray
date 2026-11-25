#!/usr/bin/env bash
# Two independent Xray nodes and counted XHTTP legs; no public probe or root needed.
set -euo pipefail
ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
XRAY_BIN="${XRAY_BIN:-xray}"
export XRAY_BIN
tmp="$(mktemp -d)"
pids=()
cleanup() {
    local status=$? p
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
    if ((status)); then tail -n 20 "$tmp"/*.log >&2 || true; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
export HOME="$tmp" KOKORO_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
python3 - "$ROOT/tools/xray-speed.py" <<'PY'
import runpy, sys
select = runpy.run_path(sys.argv[1])["select"]
assert select({"a": 100, "b": 114}, "a") == "a"
assert select({"a": 100, "b": 116}, "a") == "b"
assert select({"b": 1}, "a") == "b"
assert select({}, "a") == "BLOCK"
PY
kokoro_ensure_state
kokoro_cfg_set_str '.role' edge
kokoro_cfg_set_str '.inbound.mode' tls
kokoro_cfg_set_str '.inbound.tls.cdn_domain' speed.example
kokoro_cfg_set '.inbound.hysteria.enabled' true
kokoro_cfg_set_str '.inbound.hysteria.domain' speed.example
kokoro_cfg_set_str '.inbound.hysteria.ports' 18344
kokoro_cfg_set_str '.paths.hysteria_cert' "$tmp/cert"
kokoro_cfg_set_str '.paths.hysteria_key' "$tmp/key"
cp "$ROOT/.github/fixtures/edge-secrets.json" "$KOKORO_SECRETS"
chmod 600 "$KOKORO_SECRETS"
kokoro_sec_set_str '.inbound.hysteria.auth' test-auth
kokoro_sec_set_str '.inbound.hysteria.obfs_password' test-obfs
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=speed.example \
    -addext 'subjectAltName=DNS:speed.example' -keyout "$tmp/key" -out "$tmp/cert" >/dev/null 2>&1

jq -n -f "$ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" --slurpfile sec "$KOKORO_SECRETS" >"$tmp/edge"
for kind in vless hysteria; do
    jq --arg kind "$kind" --arg tmp "$tmp" '
        .inbounds = [.inbounds[] | select(.protocol == $kind) | .listen = "127.0.0.1" | del(.sniffing)]
        | if $kind == "vless" then .inbounds[0] |= (.port = 18340 | .streamSettings |=
            (.security = "tls" | .tlsSettings = {alpn:["h2"],certificates:[
                {certificateFile:($tmp+"/cert"),keyFile:($tmp+"/key")}]})) else . end
        | .routing = {rules:[]}
        | .outbounds = [{protocol:"freedom",settings:{finalRules:[{action:"allow",ip:["127.0.0.1/32"]}]},
            sendThrough:(if $kind == "vless" then "127.0.0.2" else "127.0.0.3" end)}]
    ' "$tmp/edge" >"$tmp/$kind-server.json"
    "$XRAY_BIN" run -config "$tmp/$kind-server.json" >"$tmp/$kind.log" 2>&1 &
    pids+=("$!")
done
cli() { bash "$ROOT/kokoro-xray.sh" link --json "$@"; }
cli xhttp-split direct-h2=127.0.0.1 direct-h2=127.0.0.1 | jq --arg cert "$tmp/cert" '
    .inbounds[0].port = 18345 | .inbounds[1].port = 18346
    | .outbounds[0] |= (.settings.vnext[0].port = 18341 | .streamSettings |=
        (.tlsSettings.certificates = [{certificateFile:$cert,usage:"verify"}]
        | .xhttpSettings.downloadSettings |= (.port = 18342 | .tlsSettings.certificates =
            [{certificateFile:$cert,usage:"verify"}])))
    | .routing.rules = [{type:"field",port:"18347",outboundTag:"BLOCK"},.routing.rules[-1]]
' >"$tmp/split.json"
cli hysteria | jq --arg cert "$tmp/cert" '
    .outbounds[0] |= (.settings.address = "127.0.0.1" | .streamSettings.tlsSettings.certificates =
        [{certificateFile:$cert,usage:"verify"}])
' >"$tmp/hy2.json"

printf '127.0.0.2\n' >"$tmp/mode"
python3 "$ROOT/tests/xray-speed-server.py" "$tmp" >"$tmp/origin.log" 2>&1 &
pids+=("$!")
target=http://127.0.0.1:18343
client_curl() { curl -q --proxy socks5h://127.0.0.1:18345 --noproxy '' -fsS --max-time 4 "$@"; }
for _ in {1..50}; do curl -q --proxy '' -fsS "$target/who" >/dev/null 2>&1 && break; sleep .1; done
start_selector() {
    bash "$ROOT/kokoro-xray.sh" speed --interval 2 --download-url "$target/down" --upload-url "$target/up" \
        "$tmp/split.json" "$1" >"$tmp/selector.log" 2>&1 &
    controller=$!
    pids+=("$controller")
}
wait_selection() {
    local want="$1" start="$2"
    for _ in {1..200}; do
        if tail -n "+$start" "$tmp/selector.log" | grep -Fx "selected $want" >/dev/null; then return; fi
        kill -0 "$controller" || return 1
        sleep .1
    done
    return 1
}
round() {
    local start
    start=$(( $(wc -l <"$tmp/selector.log") + 1 ))
    printf '%s\n' "$1" >"$tmp/mode"
    wait_selection "$2" "$start"
}
start_selector "$tmp/hy2.json"
wait_selection path-1 1
[[ "$(client_curl "$target/who")" == 127.0.0.2 ]]
# A full payload traverses opposite TLS entrances. Control frames stay small.
counts() { curl -q --proxy '' -fsS "$target/counts"; }
openssl rand -out "$tmp/body" 1048576
check_split() {
    local before
    before="$(counts)"
    client_curl --data-binary "@$tmp/body" "$target/echo" >"$tmp/echo"
    cmp "$tmp/body" "$tmp/echo"
    python3 - "$before" "$(counts)" "$1" "$2" <<'PY'
import json, sys
old, new = map(json.loads, sys.argv[1:3])
for payload_direction, leg in enumerate(sys.argv[3:]):
    delta = [n - o for n, o in zip(new[leg], old[leg])]
    assert delta[payload_direction] >= 1048576 and delta[1-payload_direction] < 131072, (leg, delta)
    print(f"{leg} entrance: {delta[0]} bytes towards edge, {delta[1]} towards client")
PY
}
check_split up down
curl -q --proxy '' -fsS http://127.0.0.1:18347/who >/dev/null
if client_curl http://127.0.0.1:18347/who >/dev/null 2>&1; then echo 'BLOCK rule leaked' >&2; exit 1; fi
client_curl --max-time 20 "$target/hold" >"$tmp/held-egress" &
held=$!
pids+=("$held")
for _ in {1..50}; do [[ -e "$tmp/holding" ]] && break; sleep .1; done
[[ -e "$tmp/holding" ]]
round 127.0.0.3 path-2
[[ "$(client_curl "$target/who")" == 127.0.0.3 ]]
touch "$tmp/release"
wait "$held"
unset 'pids[-1]'
[[ "$(cat "$tmp/held-egress")" == 127.0.0.2 ]]
round reject BLOCK
if client_curl "$target/who" >/dev/null 2>&1; then echo 'all-down leaked' >&2; exit 1; fi
round short BLOCK
grep -Fq 'HTTP 200, 1 bytes' "$tmp/selector.log"
round 127.0.0.2 path-1
[[ "$(client_curl "$target/who")" == 127.0.0.2 ]]
round xhttp-down path-2
[[ "$(client_curl "$target/who")" == 127.0.0.3 ]]
grep -E '^(path-[0-9] (up=|unavailable)|selected )' "$tmp/selector.log"
kill "$controller"
wait "$controller" || [[ $? == 143 ]]
unset 'pids[-1]'

jq '.outbounds[0] |= (.settings.vnext[0].port = 18342 | .streamSettings.xhttpSettings.downloadSettings.port = 18341)' \
    "$tmp/split.json" >"$tmp/reverse.json"
printf 'favor-forward\n' >"$tmp/mode"
start_selector "$tmp/reverse.json"
wait_selection path-1 1
round favor-reverse path-2
[[ "$(client_curl "$target/who")" == 127.0.0.2 ]]
check_split down up
grep -E '^(path-[0-9] up=|selected )' "$tmp/selector.log"
echo 'xray-speed: node switching, reversing XHTTP legs, held connection, blocking and recovery passed'
