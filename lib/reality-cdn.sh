#!/usr/bin/env bash
# CDN/WAF edge screening; a negative result is not proof of a dedicated origin.

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_reality_cdn_screen() { # hostname, newline-separated resolved addresses
    local host="$1" ips="$2" data="${KOKORO_ROOT}/data/reality-cdn.json"
    local ranges suffixes matches response nodes name suffix ip
    command -v grepcidr >/dev/null 2>&1 || {
        kokoro_warn "grepcidr is required for REALITY CDN screening (apt install grepcidr)"
        return 1
    }
    ranges="$(jq -er '.ranges | select(type == "array" and length > 0)
        | select(all(.[]; type == "string")) | .[]' "$data")" || return 1
    suffixes="$(jq -er '.suffixes | select(type == "array" and length > 0)
        | select(all(.[]; type == "string" and length > 0)) | .[]' "$data")" || return 1
    if matches="$(grepcidr -f <(printf '%s\n' "$ranges") <<<"$ips" 2>&1)"; then
        return 1
    else
        # A broken checker or malformed ranges must never mean "not a CDN".
        [[ "$?" == 1 && -z "$matches" ]] || return 1
    fi

    response="$(curl -fsS --connect-timeout 3 --max-time 8 --max-filesize 262144 \
        --get --data-urlencode "resource=$host" \
        https://stat.ripe.net/data/dns-chain/data.json)" || return 1
    nodes="$(jq -er --arg host "$host" '
        select(.status == "ok") | .data.forward_nodes
        | select(type == "object" and has($host))
        | select(.[$host] | type == "array" and length > 0)
        | select(all(.[]; type == "array" and all(.[]; type == "string")))
        | to_entries[] | .key, .value[] | ascii_downcase | rtrimstr(".")
    ' <<<"$response")" || return 1
    [[ -n "$nodes" ]] || return 1
    # Different resolver views cannot establish a clean chain for our endpoint.
    while IFS= read -r ip; do
        grep -Fxi -- "$ip" <<<"$nodes" >/dev/null || return 1
    done <<<"$ips"
    while IFS= read -r name; do
        while IFS= read -r suffix; do
            [[ "$name" != "$suffix" && "$name" != *".$suffix" ]] || return 1
        done <<<"$suffixes"
    done <<<"$nodes"
}

kokoro_reality_cdn_headers_detected() {
    grep -Eiq '^(cf-ray|cf-cache-status|x-amz-cf-id|x-amz-cf-pop|x-fastly-request-id|fastly-debug-path|x-vercel-id|x-nf-request-id|x-sucuri-id|x-sucuri-cache|x-akamai-transformed|x-iinfo):|^server:[[:space:]]*(cloudflare|akamaighost|bunnycdn|netlify|sucuri)|^x-served-by:.*cache-' <<<"$1"
}
