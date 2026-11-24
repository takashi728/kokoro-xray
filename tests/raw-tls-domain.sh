#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
source "$ROOT/lib/onboard.sh"
unset KOKORO_PUBLIC_ADDRESS

timeout() {
    shift
    "$@"
}

getent() {
    case "$*" in
        --no-addrconfig\ --help) [[ "${legacy:-false}" == false ]] ;;
        --no-addrconfig\ ahosts\ direct.example|ahosts\ direct.example)
            local address
            for address in "${dns_answers[@]}"; do
                printf '%s STREAM direct.example\n%s DGRAM\n' "$address" "$address"
            done ;;
        *) return 2 ;;
    esac
}

ip() {
    [[ "$*" == "-j -6 address show scope global" ]] || return 1
    printf '%s\n' '[{"addr_info":[{"local":"2001:db8::42"},{"local":"2001:db8::43","tentative":true}]}]'
}

curl() {
    [[ "$1" == -4 ]] || return 1
    [[ "${offline:-false}" == false ]] || return 1
    printf '%s\n' '192.0.2.42'
}

check() {
    local want="$1" got=reject
    shift
    dns_answers=("$@")
    if kokoro_raw_tls_domain_check direct.example; then got=accept; fi
    if [[ "$got" != "$want" ]]; then
        printf 'wanted %s, got %s for DNS answers: %s\n' "$want" "$got" "$*" >&2
        exit 1
    fi
}

offline=true
check accept 2001:db8::42
check reject 2001:db8::43
check reject
offline=false
check accept 192.0.2.42
check accept 192.0.2.42 2001:db8::42
check reject 192.0.2.42 2001:db8::99
check reject 192.0.2.99 2001:db8::42
check reject 192.0.2.42 192.0.2.99
offline=true
KOKORO_PUBLIC_ADDRESS=192.0.2.42 check accept 192.0.2.42
legacy=true check accept 2001:db8::42
echo 'raw-tls-domain: IPv4, AAAA-only, dual-stack, and mismatches checked'
