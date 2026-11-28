#!/usr/bin/env bash

kokoro_warp_key_der() {
    local key
    key="$(kokoro_sec '.warp.private_key // ""')" || return 1
    if [[ $key == '-----BEGIN '* ]]; then
        openssl pkey -passin pass: -outform DER <<<"$key"
    else
        printf '%s' "$key" | base64 -d
    fi
}

kokoro_warp_validate() {
    local version xray_bin endpoint
    xray_bin="$(kokoro_cfg '.paths.xray_bin')"
    version="$("$xray_bin" version | awk 'NR==1 {print $2}')" || return 1
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $(printf '%s\n' 26.10.0 "$version" | sort -V | head -1) == 26.10.0 ]] ||
        { kokoro_warn "$(kokoro_cf_text warp_version)"; return 1; }
    if ! (set -o pipefail
        kokoro_warp_key_der | openssl pkey -inform DER -passin pass: -pubout |
            openssl pkey -pubin -text -noout | grep -Fx 'ASN1 OID: prime256v1' >/dev/null
    ) 2>/dev/null; then
        kokoro_warn "$(kokoro_cf_text warp_p256)"; return 1
    fi
    endpoint="$(kokoro_cfg '.warp.endpoint')"
    if ! kokoro_cf_ip "$endpoint" || ! kokoro_cf_domain "$(kokoro_cfg '.warp.sni')" ||
       ! jq -e '.warp |
         (.account_type | IN("free","plus","zerotrust")) and (.transport | IN("h2","h3")) and
         (.port | IN(443,500,1701,4443,4500,8443,8095)) and (.mtu == 1280) and
         (.route_mode | IN("selective","all")) and (.addresses | type=="array" and length>0) and
         (.route_presets | type=="array" and all(IN("ai","streaming","google"))) and
         (.custom_domains | type=="array" and all(type=="string" and length>0)) and
         ([.enabled,.ipv4_via_warp,.finalmask.enabled,.finalmask.h3_noise_enabled] | all(type=="boolean")) and
         (.public_key | type=="string" and length>0) and
         (.pinned_peer_cert_sha256 | type=="string" and
            (.=="" or test("\\A([0-9a-fA-F]{64}|([0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2})\\z")))' "$KOKORO_CONFIG" >/dev/null; then
        kokoro_warn "$(kokoro_cf_text warp_invalid)"; return 1
    fi
}

kokoro_warp_refresh() {
    local endpoint port sni peer spki current accept=false fingerprint pin
    if [[ ${1:-} == --accept-new-pin ]]; then accept=true; shift; fi
    [[ $# == 0 ]] || kokoro_die "$(kokoro_cf_text cf_usage)"
    endpoint="$(kokoro_cfg '.warp.endpoint')"
    port="$(kokoro_cfg '.warp.port')"
    sni="$(kokoro_cfg '.warp.sni')"
    kokoro_cf_ip "$endpoint" && kokoro_cf_domain "$sni" && [[ $port =~ ^(443|500|1701|4443|4500|8443|8095)$ ]] ||
        kokoro_die "$(kokoro_cf_text warp_invalid)"
    [[ $endpoint != *:* ]] || endpoint="[$endpoint]"
    peer="$( { timeout 12 openssl s_client -connect "$endpoint:$port" -servername "$sni" -alpn h2 -tls1_3 </dev/null 2>/dev/null || true; } |
        openssl x509 -outform PEM)" || kokoro_die "$(kokoro_cf_text warp_fetch_error)"
    spki="$(openssl x509 -pubkey -noout <<<"$peer" | openssl pkey -pubin -outform DER | base64 -w0)" || return 1
    pin="$(kokoro_cfg '.warp.pinned_peer_cert_sha256 // ""')"
    if [[ -n $pin ]]; then
        fingerprint="$(openssl x509 -outform DER <<<"$peer" | sha256sum)"
        pin="${pin//:/}"
        [[ ${fingerprint%% *} == "${pin,,}" ]] || kokoro_die "$(kokoro_cf_text warp_pin_change)"
    fi
    current="$(kokoro_cfg '.warp.public_key // ""')"
    if [[ $current == '-----BEGIN '* ]]; then
        current="$(openssl pkey -pubin -outform DER <<<"$current" | base64 -w0)" || return 1
    fi
    [[ -z $current || $current == "$spki" || $accept == true ]] || kokoro_die "$(kokoro_cf_text warp_pin_change)"
    kokoro_cfg_set_str '.warp.public_key' "$spki"
}

kokoro_warp_setup() {
    local account transport route presets endpoint="" family=4 import="" key_file="" addresses="" spki="" pin="" port sni
    account="$(kokoro_cfg '.warp.account_type')"; transport="$(kokoro_cfg '.warp.transport')"
    route="$(kokoro_cfg '.warp.route_mode')"; presets="$(kokoro_cfg '.warp.route_presets | join(",")')"
    port="$(kokoro_cfg '.warp.port')"; sni="$(kokoro_cfg '.warp.sni')"
    if [[ $# == 0 && -t 0 ]]; then
        account="$(kokoro_cf_prompt warp_account "$account")"
        transport="$(kokoro_cf_prompt warp_transport "$transport")"
        route="$(kokoro_cf_prompt warp_route "$route")"
        presets="$(kokoro_cf_prompt warp_presets "$presets")"
        key_file="$(kokoro_cf_prompt warp_key_file "")"
        addresses="$(kokoro_cf_prompt warp_addresses "")"
    fi
    while (( $# )); do
        [[ $# -ge 2 ]] || kokoro_die "$(kokoro_cf_text cf_usage)"
        case "$1" in
            --account-type) account="$2" ;; --transport) transport="$2" ;; --route-mode) route="$2" ;;
            --route-presets) presets="$2" ;; --endpoint) endpoint="$2" ;; --port) port="$2" ;;
            --family) family="$2" ;; --private-key-file) key_file="$2" ;; --addresses) addresses="$2" ;;
            --import-usque) import="$2" ;; --public-key) spki="$2" ;; --sni) sni="$2" ;;
            --cert-pin) pin="$2" ;; *) kokoro_die "$(kokoro_cf_text cf_usage)" ;;
        esac
        shift 2
    done
    local subnet
    case "$account/$family" in
        free/4) subnet=198 ;; plus/4) subnet=199 ;; zerotrust/4) subnet=197 ;;
        free/6) subnet=103 ;; plus/6) subnet=104 ;; zerotrust/6) subnet=102 ;;
        *) kokoro_die "$(kokoro_cf_text warp_invalid)" ;;
    esac
    if [[ -z $endpoint ]]; then
        if [[ $family == 6 ]]; then endpoint="2606:4700:$subnet::2"; else endpoint="162.159.$subnet.2"; fi
    fi
    if [[ -n $import ]]; then
        jq -er '.private_key | strings | select(length>0)' "$import" |
            kokoro_cf_secret '.warp.private_key'
        addresses="$(jq -er '[.ipv4,.ipv6] | map(strings|select(length>0))|join(",")' "$import")"
        if [[ -z $spki ]]; then spki="$(jq -r '.endpoint_pub_key // ""' "$import")"; fi
    elif [[ -n $key_file ]]; then kokoro_cf_secret '.warp.private_key' <"$key_file"; fi
    # shellcheck disable=SC2016
    kokoro_write_private "$KOKORO_CONFIG" jq --arg account "$account" --arg transport "$transport" \
        --arg route "$route" --arg presets "$presets" --arg endpoint "$endpoint" --arg addresses "$addresses" \
        --arg spki "$spki" --arg pin "$pin" --arg port "$port" --arg sni "$sni" '
        .warp |= (. + {enabled:true,account_type:$account,transport:$transport,route_mode:$route,
          route_presets:($presets|split(",")),endpoint:$endpoint,port:($port|tonumber),sni:$sni}
          | if $addresses!="" then .addresses=($addresses|split(",")) else . end
          | if $spki!="" then .public_key=$spki else . end
          | if $pin!="" then .pinned_peer_cert_sha256=$pin else . end)' "$KOKORO_CONFIG"
    kokoro_state_refresh
    if [[ -z $(kokoro_cfg '.warp.public_key') ]]; then kokoro_warp_refresh "$@"; fi
}

kokoro_warp_status() {
    printf 'WARP MASQUE %s\n' "$(jq -cr '.warp | {enabled,account_type,transport,endpoint,port,sni,route_mode,route_presets}' "$KOKORO_CONFIG")"
    printf 'P-256 (%s): %s\n' "$(kokoro_cf_text cf_configured)" "$(jq '.warp.private_key | strings | length>0' "$KOKORO_SECRETS")"
}

kokoro_warp_test() (
    set -euo pipefail
    local speed=false port trace retry xray_bin
    warp_probe_pid=""
    if [[ ${1:-} == --speed ]]; then speed=true; shift; fi
    [[ $# == 0 && $(kokoro_cfg '.warp.enabled') == true ]] || kokoro_die "$(kokoro_cf_text warp_invalid)"
    kokoro_validate_service_paths
    kokoro_warp_validate
    xray_bin="$(kokoro_cfg '.paths.xray_bin')"
    warp_probe_dir="$(mktemp -d)"
    trap 'if [[ -n $warp_probe_pid ]]; then kill "$warp_probe_pid" 2>/dev/null || true; wait "$warp_probe_pid" 2>/dev/null || true; fi; rm -rf -- "$warp_probe_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    port="$(shuf -i 30000-60000 -n1)"
    umask 077
    jq -n -f "$KOKORO_ROOT/lib/render.jq" --slurpfile cfg "$KOKORO_CONFIG" --slurpfile sec "$KOKORO_SECRETS" |
        jq --argjson port "$port" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$port,protocol:"socks"}],
            outbounds:[.outbounds[]|select(.tag=="warp-masque")]}' >"$warp_probe_dir/probe.json"
    "$xray_bin" run -c "$warp_probe_dir/probe.json" >"$warp_probe_dir/log" 2>&1 &
    warp_probe_pid=$!
    for ((retry=0; retry<50; retry++)); do
        kill -0 "$warp_probe_pid" || return 1
        if ss -Hltnp "sport = :$port" | grep -F "pid=$warp_probe_pid," >/dev/null; then break; fi
        sleep .1
    done
    ss -Hltnp "sport = :$port" | grep -F "pid=$warp_probe_pid," >/dev/null || return 1
    local -a curl_probe=(curl --fail --silent --show-error --max-time 30 --noproxy "" --proxy "socks5h://127.0.0.1:$port")
    trace="$("${curl_probe[@]}" -w '\nseconds=%{time_total}\n' https://www.cloudflare.com/cdn-cgi/trace)"
    grep -Ex 'warp=(on|plus)' <<<"$trace"
    grep -Ex 'colo=[A-Z]{3}' <<<"$trace"
    grep '^seconds=' <<<"$trace"
    if [[ $speed == true ]]; then
        "${curl_probe[@]}" -o /dev/null -w 'warp_bytes_per_sec=%{speed_download}\n' 'https://speed.cloudflare.com/__down?bytes=20000000'
        curl -fsS --max-time 30 --noproxy '*' -o /dev/null -w 'direct_bytes_per_sec=%{speed_download}\n' 'https://speed.cloudflare.com/__down?bytes=20000000'
    fi
)
