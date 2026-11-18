#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" KOKORO_ROOT="$ROOT"
source "$ROOT/lib/hysteria-hop.sh"
kokoro_need_root() { :; }
kokoro_cfg() {
    case "$1" in
        .role) printf 'edge\n' ;;
        '.inbound.hysteria.enabled // false') printf 'true\n' ;;
        .inbound.hysteria.ports) printf '443,20000-20020\n' ;;
        *) return 1 ;;
    esac
}
mock_filter() {
    local bin="$1"
    shift
    printf '%s %s\n' "$bin" "$*" >>"$TMP/commands"
    case " $* " in
        *' -C '*|*' -L '*) return 1 ;;
    esac
    if [[ "${FAIL_IPV6:-false}" == true && "$bin" == ip6tables && " $* " == *' -N '* ]]; then return 1; fi
}
iptables() { mock_filter iptables "$@"; }
ip6tables() { mock_filter ip6tables "$@"; }
kokoro_hysteria_hop_start
for bin in iptables ip6tables; do
    grep -Fx "$bin -w 5 -t nat -A KOKORO_HY2 -p udp --dport 20000:20020 -j REDIRECT --to-ports 443" "$TMP/commands"
    grep -Fx "$bin -w 5 -t nat -A PREROUTING -p udp -m addrtype --dst-type LOCAL -j KOKORO_HY2" "$TMP/commands"
done
! grep -q -- '-A OUTPUT' "$TMP/commands"
! grep -q -- '--dport 443 ' "$TMP/commands"
FAIL_IPV6=true
if kokoro_hysteria_hop_start; then
    echo 'IPv6 redirect installation failure was swallowed' >&2
    exit 1
fi
[[ "$(grep -c -- '-C PREROUTING' "$TMP/commands")" -ge 6 ]]
echo 'hysteria-hop-test OK'
