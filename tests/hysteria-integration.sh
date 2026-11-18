#!/usr/bin/env bash
# Optional live regression: run on a client outside the HY2 server, not a NAT hairpin.
set -euo pipefail
: "${HY2_CLIENT_JSON:?set HY2_CLIENT_JSON to the exported client profile}"
: "${EXPECTED_EGRESS:?set EXPECTED_EGRESS to the server IPv4}"
XRAY_BIN="${XRAY_BIN:-xray}"
umask 077
TMP="$(mktemp -d)"
pid=''
cleanup() {
    local status=$?
    [[ "$status" == 0 || ! -f "$TMP/client.log" ]] || tail -n 15 "$TMP/client.log" >&2
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
    [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT
interval="$(jq -er '[.outbounds[0].streamSettings.finalmask.udp[]
    | select(.type == "udphop") | .settings.interval | split("-")[-1] | tonumber][0]' "$HY2_CLIENT_JSON")"
[[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 5 && "$interval" -le 120 ]]
jq '(.outbounds[0].settings.port | tostring) as $primary
    | .inbounds = [.inbounds[0] | .port=19428]
    | .outbounds[0].streamSettings.finalmask.udp |= map(
        if .type == "udphop" then
            .settings.remotePorts |= (split(",") | map(select(. != $primary)) | join(","))
        else . end)' "$HY2_CLIENT_JSON" >"$TMP/client.json"
"$XRAY_BIN" run -config "$TMP/client.json" >"$TMP/client.log" 2>&1 &
pid=$!
sleep 1
for phase in initial after-hop second-hop; do
    [[ "$phase" == initial ]] || sleep "$((interval + 2))"
    ip="$(curl --noproxy '' --socks5-hostname 127.0.0.1:19428 -fsS --max-time 35 https://api.ipify.org)"
    [[ "$ip" == "$EXPECTED_EGRESS" ]]
    printf 'HY2 %s egress verified: %s\n' "$phase" "$ip"
done
