#!/usr/bin/env bash
# Run on the operator machine. No Cloudflare credentials are needed on the VPS.
set -euo pipefail

die() { printf 'cf-xhttp-dns: %s\n' "$*" >&2; exit 1; }
[[ $# == 4 ]] || die "usage: bash tools/cf-xhttp-dns.sh prepare|proxy ZONE HOST ORIGIN_IP"
action="$1" zone_name="${2,,}" host="${3,,}" origin="$4"
case "$action" in prepare|proxy) ;; *) die "expected prepare or proxy" ;; esac
dns_name='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$'
[[ "$zone_name" =~ $dns_name && "$host" =~ $dns_name && "$host" == *."$zone_name" ]] ||
    die "HOST must be a subdomain of ZONE"
address="$(node -e '
    const ip = process.argv[1];
    switch (require("node:net").isIP(ip)) {
      case 4: console.log(ip); break;
      case 6: console.log(new URL("http://[" + ip + "]/").hostname); break;
      default: process.exitCode = 1;
    }
' "$origin")" || die "ORIGIN_IP must be an IPv4 or unbracketed IPv6 literal"
type=A
if [[ "$address" == \[*\] ]]; then
    type=AAAA
    origin="${address:1:-1}"
fi

zone="$(cf zones list --name "$zone_name" --per-page 5 | jq -er --arg name "$zone_name" '
    map(select(.name == $name and .status == "active"))
    | select(length == 1) | .[0].id | strings | select(length > 0)
')" || die "expected one active Cloudflare zone for $zone_name"
comment=kokoro-xhttp-split
records="$(cf dns records list --zone "$zone" --name "$host" --per-page 5 |
    jq -ec 'select(type == "array")')" || die "could not read existing DNS records"
if [[ "$records" == '[]' ]]; then
    [[ "$action" == prepare ]] || die "no record; run prepare first"
    body="$(jq -cn --arg name "$host" --arg type "$type" --arg content "$origin" --arg comment "$comment" '
        {$name,$type,$content,$comment,ttl:1,proxied:false}
    ')"
    cf dns records create --zone "$zone" --body "$body" --dry-run >/dev/null
    cf dns records create --zone "$zone" --body "$body" |
        jq -e --arg name "$host" '.name == $name and .proxied == false' >/dev/null
    printf '%s created DNS-only. Issue the origin certificate before proxying.\n' "$host"
    exit 0
fi

record="$(jq -ec --arg name "$host" --arg type "$type" --arg content "$origin" --arg comment "$comment" '
    select(length == 1) | .[0]
    | select(.name == $name and .type == $type and .content == $content and .comment == $comment)
' <<<"$records")" || die "existing record differs or is not owned by this helper; no changes made"
proxied="$(jq -er '.proxied | tostring' <<<"$record")"
if [[ "$action" == prepare || "$proxied" == true ]]; then
    printf '%s already exists (proxied=%s).\n' "$host" "$proxied"
    exit 0
fi

cf zones settings get ssl --zone "$zone" | jq -e '.value == "strict"' >/dev/null ||
    die "zone must already use Full (strict); no zone-wide settings changed"
curl --noproxy '*' --proto '=https' --resolve "$host:443:$address" \
    --connect-timeout 5 --max-time 12 -fsS -o /dev/null "https://$host/" ||
    die "verified HTTPS to origin failed; keeping DNS-only"
record_id="$(jq -er '.id | strings | select(length > 0)' <<<"$record")"
cf dns records edit "$record_id" --zone "$zone" --body '{"proxied":true}' --dry-run >/dev/null
cf dns records edit "$record_id" --zone "$zone" --body '{"proxied":true}' |
    jq -e --arg name "$host" '.name == $name and .proxied == true' >/dev/null
printf '%s now proxied.\n' "$host"
