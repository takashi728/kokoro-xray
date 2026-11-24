#!/usr/bin/env bash
# Combine three local Kokoro client exports; output contains live credentials.
set -euo pipefail

if [[ $# != 3 ]]; then
    printf '%s\n' 'Usage: bash tools/xhttp-round-robin.sh DIRECT_XHTTP.json SPLIT_XHTTP.json HY2.json' >&2
    exit 2
fi

jq -ne --slurpfile direct "$1" --slurpfile split "$2" --slurpfile hy2 "$3" '
    def single:
        if length == 1 and (.[0] | type == "object") then .[0]
        else error("expected one JSON profile per input file") end;
    def xhttp: .protocol == "vless" and .streamSettings.network == "xhttp";

    ($direct | single) as $base
    | $base.outbounds[0] as $d
    | ($split | single | .outbounds[0]) as $s
    | ($hy2 | single | .outbounds[0]) as $h
    | if ($d | xhttp and .streamSettings.xhttpSettings.downloadSettings == null)
         and ($s | xhttp and (.streamSettings.xhttpSettings.downloadSettings | type == "object"))
         and ($h | .protocol == "hysteria" and .settings.version == 2)
      then .
      else error("expected direct XHTTP, split XHTTP, and Hysteria2 exports in that order")
      end
    | ($base.outbounds | map(select(.tag == "BLOCK" and .protocol == "blackhole"))) as $block
    | if ($block | length == 1)
         and ($d.tag | type == "string" and length > 0 and . != "BLOCK")
         and ($base.routing.rules | type == "array"
            and .[-1] == {type:"field",network:"tcp,udp",outboundTag:$d.tag}
            and all(.[]; .outboundTag == $d.tag or .outboundTag == "BLOCK"))
         and ($base.routing.balancers // [] | length == 0)
         and $base.observatory == null and $base.burstObservatory == null
      then .
      else error("expected a standalone Kokoro XHTTP profile with its default blocking rules")
      end
    | ["kokoro-rr-hy2","kokoro-rr-direct","kokoro-rr-split"] as $tags
    | "kokoro-round-robin" as $group
    | $base
    | .outbounds = [($h | .tag = $tags[0]), ($d | .tag = $tags[1]), ($s | .tag = $tags[2])] + $block
    | .routing.rules |= map(
        if .outboundTag == $d.tag then del(.outboundTag) | .balancerTag = $group else . end)
    | .routing.balancers = [{tag:$group, selector:$tags, strategy:{type:"roundRobin"}, fallbackTag:"BLOCK"}]
    | .observatory = {
        subjectSelector:$tags,
        probeUrl:"https://www.gstatic.com/generate_204",
        probeInterval:"30s",
        enableConcurrency:true
      }
'
