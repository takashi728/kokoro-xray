#!/usr/bin/env bash
set -euo pipefail
umask 077
KOKORO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KOKORO_ROOT
work="$(mktemp -d)"
children=()
cleanup() {
    local pid
    for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    rm -rf -- "$work"
}
trap cleanup EXIT
export HOME="$work" KOKORO_PUBLIC_ADDRESS=192.0.2.1
source "$KOKORO_ROOT/lib/link.sh"
source "$KOKORO_ROOT/lib/warp.sh"
kokoro_ensure_state
kokoro_load_i18n
bin="$(realpath "${XRAY_BIN:-$(command -v xray)}")"
if [[ -f $(dirname "$bin")/geosite.dat ]]; then
    export XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-$(dirname "$bin")}"
fi
render() {
    jq -n -f "$KOKORO_ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" --slurpfile sec "$KOKORO_SECRETS" >"$work/server.json"
}
dry_run() {
    render
    "$bin" run -test -config "$work/server.json" >"$work/check" || { tail -n1 "$work/check" >&2; return 1; }
}
for role in edge exit; do
    cp "$KOKORO_ROOT/.github/fixtures/$role-config.json" "$KOKORO_CONFIG"
    cp "$KOKORO_ROOT/.github/fixtures/$role-secrets.json" "$KOKORO_SECRETS"
    render
    if [[ $role == edge ]]; then legacy_hash=5d935371e33b43b4110d36278d25bc2a358db8e7d3e12bebd0d156c710ffb172
    else legacy_hash=e97971e370830daed985a8c2f6e506a93384bbe7fdef48a32687474848560c4e; fi
    [[ $(jq -cS . "$work/server.json" | sha256sum) == "$legacy_hash  -" ]]
    cp "$work/server.json" "$work/legacy"
    kokoro_migrate_merge_defaults
    render
    cmp "$work/legacy" "$work/server.json"
done
cp "$KOKORO_ROOT/config.defaults.json" "$KOKORO_CONFIG"
cp "$KOKORO_ROOT/secrets.defaults.json" "$KOKORO_SECRETS"
kokoro_state_refresh
kokoro_cfg_set_str .paths.xray_bin "$bin"
kokoro_cfg_set_str .role edge
kokoro_cfg_set_str .inbound.mode argo
kokoro_sec_set_str .inbound.uuid "$("$bin" uuid)"
"$bin" vlessenc >"$work/vless"
for field in encryption decryption; do
    awk -F'"' -v field="$field" '$2==field {print $4; exit}' "$work/vless" |
        kokoro_cf_secret ".inbound.vless_encryption.$field"
done
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 >"$work/device.pem"
openssl pkey -in "$work/device.pem" -outform DER | base64 -w0 >"$work/device.b64"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 | openssl pkey -pubout >"$work/peer.pem"
jq -n --rawfile key "$work/device.b64" --rawfile peer "$work/peer.pem" \
    '{private_key:$key,endpoint_pub_key:$peer,ipv4:"172.16.0.2",ipv6:"2001:db8::2"}' >"$work/usque.json"
kokoro_warp_setup --import-usque "$work/usque.json"
kokoro_warp_validate
(
    openssl req -new -x509 -key "$work/device.pem" -subj '/CN=test.invalid' -days 1 -out "$work/leaf.pem"
    timeout() { cat "$work/leaf.pem"; }
    if (kokoro_warp_refresh) 2>/dev/null; then exit 1; fi
    kokoro_warp_refresh --accept-new-pin
    [[ $(kokoro_cfg '.warp.public_key') == "$(openssl pkey -in "$work/device.pem" -pubout -outform DER | base64 -w0)" ]]
    kokoro_cfg_set_str .warp.pinned_peer_cert_sha256 "$(openssl rand -hex 32)"
    if (kokoro_warp_refresh --accept-new-pin) 2>/dev/null; then exit 1; fi
    kokoro_cfg_set_str .warp.pinned_peer_cert_sha256 ''
)
kokoro_state_refresh
dry_run
jq -e '.outbounds[0].tag=="DIRECT" and
  (.outbounds[]|select(.tag=="warp-masque").streamSettings|
    .tlsSettings.alpn==["h3"] and (has("finalmask")|not) and
    (.tlsSettings|keys|sort)==["alpn","serverName"]) and
  any(.routing.rules[]; .outboundTag=="warp-masque" and (.domain|index("geosite:openai"))!=null)' "$work/server.json" >/dev/null
kokoro_cfg_set .warp.finalmask.enabled true
kokoro_cfg_set .warp.finalmask.h3_noise_enabled true
dry_run
jq -e '.outbounds[]|select(.tag=="warp-masque").streamSettings.finalmask.udp[0].type=="noise"' "$work/server.json" >/dev/null
kokoro_cfg_set_str .warp.transport h2
kokoro_cfg_set_str .warp.route_mode all
kokoro_cfg_set .warp.ipv4_via_warp true
kokoro_cfg_set .warp.custom_domains '["full:test.example"]'
dry_run
jq -e '.outbounds[0] | .tag=="warp-masque" and .streamSettings.tlsSettings.alpn==["h2"]
    and .streamSettings.finalmask.tcp[0].type=="fragment"' "$work/server.json" >/dev/null
kokoro_cfg_set_str .warp.pinned_peer_cert_sha256 "$(openssl rand -hex 32)"
dry_run
for role in edge exit; do
    jq -s '.[0] * .[1]' "$KOKORO_CONFIG" "$KOKORO_ROOT/.github/fixtures/$role-config.json" >"$work/paired.json"
    jq -s '.[0] * .[1]' "$KOKORO_SECRETS" "$KOKORO_ROOT/.github/fixtures/$role-secrets.json" >"$work/paired-secrets.json"
    jq -n -f "$KOKORO_ROOT/lib/render.jq" --slurpfile cfg "$work/paired.json" --slurpfile sec "$work/paired-secrets.json" >"$work/paired-render.json"
    if [[ $role == edge ]]; then jq -e '.outbounds[0].tag=="WG_TO_EXIT"' "$work/paired-render.json" >/dev/null
    else
        jq -e '(.inbounds[0].sniffing.routeOnly==true) and
          ([.routing.rules[].outboundTag] | index("TOR") < index("warp-masque"))' "$work/paired-render.json" >/dev/null
    fi
done
openssl rand -base64 32 | kokoro_cf_secret '.warp.private_key'
kokoro_state_refresh_sec
if kokoro_warp_validate >"$work/error" 2>&1; then exit 1; fi
grep -q 'P-256' "$work/error"
kokoro_cf_secret '.warp.private_key' <"$work/device.pem"
kokoro_warp_validate
printf '%s\n' sentinelTunnelToken >"$work/token"
kokoro_argo_setup --mode named --hostname tunnel.example.org --token-file "$work/token"
kokoro_argo_validate
dry_run
jq -e '.inbounds[]|select(.tag=="in-argo-xhttp")|
    .listen=="127.0.0.1" and .port==18080 and .settings.decryption!="none" and .streamSettings.security=="none"' "$work/server.json" >/dev/null
kokoro_argo_unit >"$work/unit"
grep -q '^DynamicUser=yes' "$work/unit"
grep -q '^EnvironmentFile=/etc/kokoro-xray/cloudflared.env$' "$work/unit"
kokoro_argo_env | cmp - <(printf 'TUNNEL_TOKEN=sentinelTunnelToken\n')
if [[ -n ${CLOUDFLARED_BIN:-} ]]; then
    bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / --dev /dev --proc /proc \
        --tmpfs /etc --dir /etc/systemd/system --tmpfs /run --tmpfs /usr/local/bin --tmpfs /tmp --tmpfs /var/tmp \
        --ro-bind "$CLOUDFLARED_BIN" /tmp/test-connector --setenv CLOUDFLARED_BIN /tmp/test-connector \
        --bind "$work" "$work" --setenv TMPDIR "$work" bash -eu -o pipefail -c '
        source "$KOKORO_ROOT/lib/cloudflare.sh"
        source "$KOKORO_ROOT/lib/argo.sh"
        kokoro_state_refresh
        systemctl() { printf "%s\n" "$*" >>"$HOME/service-actions"; }
        cp /usr/bin/true /usr/local/bin/cloudflared
        if (kokoro_argo_install) >/dev/null 2>&1; then exit 1; fi
        cp "$CLOUDFLARED_BIN" /usr/local/bin/cloudflared
        chmod 755 /usr/local/bin/cloudflared
        kokoro_argo_sync
        envfile=/etc/kokoro-xray/cloudflared.env
        unit=/etc/systemd/system/kokoro-cloudflared.service
        [[ $(stat -c %a "$envfile") == 600 ]]
        cmp "$unit" "$HOME/unit"
        kokoro_argo_env | cmp - "$envfile"
        kokoro_argo_sync
        [[ $(grep -c "^restart " "$HOME/service-actions") == 1 ]]
        kokoro_cfg_set .argo.enabled false
        kokoro_argo_sync
        [[ ! -e $unit && ! -e $envfile ]]
        grep -q "^disable --now kokoro-cloudflared.service$" "$HOME/service-actions"
    '
    kokoro_cfg_set .argo.enabled true
fi
kokoro_cfg_set_str .inbound.transport raw
bash "$KOKORO_ROOT/kokoro-xray.sh" link --json argo --cf-ip 2001:db8::1 >"$work/client.json"
jq -e '.outbounds[0] | .settings.vnext[0].address=="2001:db8::1" and
    .streamSettings.network=="xhttp" and .streamSettings.tlsSettings.serverName=="tunnel.example.org" and
    .streamSettings.xhttpSettings.host=="tunnel.example.org"' "$work/client.json" >/dev/null
"$bin" run -test -config "$work/client.json" >"$work/check" || { tail -n1 "$work/check" >&2; exit 1; }
bash "$KOKORO_ROOT/kokoro-xray.sh" link --cf-ip 2001:db8::1 >"$work/links"
grep -Fq '@[2001:db8::1]:443?' "$work/links"
for status in 'warp status' 'argo status' status; do
    read -ra args <<<"$status"
    bash "$KOKORO_ROOT/kokoro-xray.sh" "${args[@]}" >>"$work/status"
done
if grep -Fq -f "$work/token" -f "$work/device.b64" -e 'BEGIN PRIVATE KEY' "$work/unit" "$work/status" "$work/links" "$work/client.json" "$KOKORO_CONFIG"; then exit 1; fi
mapfile -t ports < <(shuf -i 30000-49000 -n3)
mkdir "$work/site"
printf '%s\n' 'local-xhttp-round-trip' >"$work/site/sample"
python3 -m http.server "${ports[0]}" --bind 127.0.0.1 --directory "$work/site" >"$work/http.log" 2>&1 &
children+=("$!")
jq --argjson port "${ports[1]}" --argjson origin "${ports[0]}" '{inbounds:[.inbounds[]|select(.tag=="in-argo-xhttp")|.port=$port],
    outbounds:[{protocol:"freedom",settings:{finalRules:[{action:"allow",ip:["127.0.0.1/32"],port:$origin}]}}]}' \
    "$work/server.json" >"$work/loopback.json"
"$bin" run -c "$work/loopback.json" >"$work/origin.log" 2>&1 &
children+=("$!")
jq --argjson origin "${ports[1]}" --argjson socks "${ports[2]}" '
    {inbounds:[.inbounds[0]|.port=$socks],outbounds:[.outbounds[0]|
      .settings.vnext[0] += {address:"127.0.0.1",port:$origin} |
      .streamSettings |= (del(.tlsSettings) | .security="none")]}' "$work/client.json" >"$work/local-client.json"
"$bin" run -c "$work/local-client.json" >"$work/client.log" 2>&1 &
children+=("$!")
curl --retry 4 --retry-delay 1 --retry-all-errors --max-time 5 --noproxy '' -fsS \
    --proxy "socks5h://127.0.0.1:${ports[2]}" "http://127.0.0.1:${ports[0]}/sample" -o "$work/received"
cmp "$work/site/sample" "$work/received"
kokoro_cfg_set .argo.local_port 8444
if kokoro_argo_validate 2>/dev/null; then exit 1; fi
kokoro_cfg_set .argo.local_port 18080
kokoro_cfg_set .firewall.extra_allow '["18079-18081/tcp"]'
if kokoro_argo_validate 2>/dev/null; then exit 1; fi
kokoro_cfg_set .firewall.extra_allow '[]'
(
    kokoro_argo_setup --mode quick --protocol http2
    kokoro_argo_validate
    kokoro_argo_unit >"$work/quick.service"
    grep -Fq -- '--protocol http2 --url http://127.0.0.1:18080' "$work/quick.service"
    if grep -q EnvironmentFile "$work/quick.service"; then exit 1; fi
    systemctl() { printf '%032d\n' 7; }
    journalctl() {
        [[ ${*: -1} == '_SYSTEMD_INVOCATION_ID=00000000000000000000000000000007' ]] || return 1
        printf '| https://fixture-only.trycloudflare.com |\n'
    }
    [[ $(kokoro_argo_hostname) == fixture-only.trycloudflare.com ]]
)
kokoro_state_refresh
kokoro_cfg_set .inbound.vless_encryption.enabled false
if kokoro_argo_validate 2>/dev/null || render 2>/dev/null; then exit 1; fi
(
    cp "$KOKORO_ROOT/config.defaults.json" "$KOKORO_CONFIG"
    cp "$KOKORO_ROOT/secrets.defaults.json" "$KOKORO_SECRETS"
    kokoro_state_refresh
    kokoro_need_root() { :; }
    set +e
    kokoro_cf_run argo setup --mode named --hostname tunnel.example.org --token-file "$work/token" >"$work/invalid" 2>&1
    result=$?
    set -e
    (( result != 0 ))
    cmp "$KOKORO_CONFIG" "$KOKORO_ROOT/config.defaults.json"
    cmp "$KOKORO_SECRETS" "$KOKORO_ROOT/secrets.defaults.json"
)
printf 'Cloudflare rendering, validation, links and redaction OK\n'
