#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
node_bin="${NODE_BIN:-$(command -v node || true)}"
tmp="$(mktemp -d)"
pids=()
cleanup() {
    local status=$? pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    if (( status != 0 )) && [[ -f "$tmp/xray.log" ]]; then tail -n 30 "$tmp/xray.log" >&2; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
export HOME="$tmp" KOKORO_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
kokoro_ensure_state
kokoro_cfg_set_str '.role' edge
kokoro_cfg_set_str '.inbound.mode' tls
kokoro_cfg_set_str '.inbound.tls.cdn_domain' direct.example.com
kokoro_cfg_set_str '.inbound.tls.split_domain' split.example.com
kokoro_cfg_set '.inbound.hysteria.enabled' true
kokoro_cfg_set_str '.inbound.hysteria.domain' hy2.example.com
cp "$ROOT/.github/fixtures/edge-secrets.json" "$KOKORO_SECRETS"
chmod 600 "$KOKORO_SECRETS"
kokoro_sec_set_str '.inbound.hysteria.auth' fixture-auth
kokoro_sec_set_str '.inbound.hysteria.obfs_password' fixture-obfs
cli() { bash "$ROOT/kokoro-xray.sh" link --json "$@"; }
combine() { bash "$ROOT/tools/xhttp-round-robin.sh" "$@"; }
cli xhttp-split direct-h2=192.0.2.42 >"$tmp/direct.json"
cli xhttp-split cdn-h2 direct-h2=2001:db8::42 >"$tmp/split.json"
cli hysteria >"$tmp/hy2.json"
combine "$tmp/direct.json" "$tmp/split.json" "$tmp/hy2.json" >"$tmp/round.json"
if combine "$tmp/split.json" "$tmp/direct.json" "$tmp/hy2.json" >/dev/null 2>&1; then
    echo 'wrong profile order was accepted' >&2; exit 1
fi
jq '.routing.rules[-1].outboundTag = "DIRECT"' "$tmp/direct.json" >"$tmp/bad.json"
if combine "$tmp/bad.json" "$tmp/split.json" "$tmp/hy2.json" >/dev/null 2>&1; then
    echo 'direct fallback was accepted' >&2; exit 1
fi
jq -e --slurpfile d "$tmp/direct.json" --slurpfile s "$tmp/split.json" --slurpfile h "$tmp/hy2.json" '
    .inbounds == $d[0].inbounds and .dns == $d[0].dns
    and (.outbounds | map(del(.tag))) ==
        ([$h[0].outbounds[0], $d[0].outbounds[0], $s[0].outbounds[0],
          ($d[0].outbounds[] | select(.tag == "BLOCK"))] | map(del(.tag)))
    and .routing.rules == ($d[0].routing.rules | map(
        if .outboundTag == "kokoro-tls" then del(.outboundTag) + {balancerTag:"kokoro-round-robin"} else . end))
    and .routing.balancers[0].strategy.type == "roundRobin"
    and .routing.balancers[0].fallbackTag == "BLOCK"
    and .routing.balancers[0].selector == [.outbounds[] | select(.tag != "BLOCK").tag]
    and .observatory.subjectSelector == .routing.balancers[0].selector
' "$tmp/round.json" >/dev/null

xray_bin="${XRAY_BIN:-$(command -v xray || true)}"
if [[ -n "$xray_bin" ]]; then "$xray_bin" run -test -config "$tmp/round.json"; fi
echo 'xhttp-round-robin: profile, preserved policies, and rejection checks passed'
[[ "${KOKORO_TEST_ROUND_ROBIN_RUNTIME:-false}" == true ]] || exit 0
: "${xray_bin:?runtime test needs Xray}"
: "${node_bin:?runtime test needs Node.js}"

touch "$tmp/disabled"
"$node_bin" - "$tmp/disabled" >"$tmp/http-port" <<'JS' &
const { readFileSync } = require('node:fs');
const server = require('node:http').createServer((req, res) => {
    const addr = req.socket.remoteAddress;
    if (req.url === '/health' && readFileSync(process.argv[2], 'utf8').split(/\s+/).includes(addr)) {
        return req.socket.destroy();
    }
    res.end(addr);
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
JS
pids+=("$!")
for i in {1..30}; do [[ ! -s "$tmp/http-port" ]] || break; sleep .1; done
target="http://127.0.0.1:$(cat "$tmp/http-port")"
port=19178
jq --arg probe "$target/health" --argjson port "$port" '
    .log.loglevel = "info"
    | .inbounds = [(.inbounds[] | select(.protocol == "socks") | .port = $port)]
    | .outbounds[0:3] |= (to_entries | map({
        tag:.value.tag, protocol:"freedom", sendThrough:("127.0.0." + ((.key + 2) | tostring))
      }))
    | .routing.rules = [.routing.rules[-1]]
    | .observatory.probeUrl = $probe | .observatory.probeInterval = "1s"
' "$tmp/round.json" >"$tmp/runtime.json"
"$xray_bin" run -config "$tmp/runtime.json" >"$tmp/xray.log" 2>&1 &
pids+=("$!")
wait_for() {
    for i in {1..50}; do grep -Fq "$1" "$tmp/xray.log" && return; sleep .1; done
    return 1
}
request() {
    curl --noproxy '' -fsS --max-time 3 --proxy "socks5h://127.0.0.1:$port" "$target/"
}
for tag in hy2 direct split; do wait_for "the outbound kokoro-rr-$tag is alive"; done
hits=()
for i in {1..6}; do hits+=("$(request)"); done
[[ "$(printf '%s\n' "${hits[@]:0:3}" | sort -u | wc -l)" == 3 ]]
[[ "${hits[*]:0:3}" == "${hits[*]:3:3}" ]]
printf '127.0.0.4\n' >"$tmp/disabled"
wait_for 'the outbound kokoro-rr-split is dead'
hits=()
for i in {1..4}; do hits+=("$(request)"); done
[[ "$(printf '%s\n' "${hits[@]}" | sort | uniq -c | awk '{$1=$1;print}')" == $'2 127.0.0.2\n2 127.0.0.3' ]]
printf '%s\n' 127.0.0.2 127.0.0.3 127.0.0.4 >"$tmp/disabled"
for tag in hy2 direct; do wait_for "the outbound kokoro-rr-$tag is dead"; done
if request >/dev/null 2>&1; then echo 'all-down request was not blocked' >&2; exit 1; fi
echo 'xhttp-round-robin: Xray cycled all three, skipped a down path, and blocked when all were down'
