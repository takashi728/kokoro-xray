#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
state="$(mktemp)"
trap 'rm -f -- "$state"' EXIT
export CF_TEST_STATE="$state" CF_TEST_SSL=strict CF_TEST_TLS=yes
printf '[]\n' >"$state"

cf() {
    case "$1 $2 $3" in
        'zones list --name') printf '[{"name":"example.com","status":"active","id":"zone"}]\n' ;;
        'zones settings get') jq -cn --arg value "$CF_TEST_SSL" '{$value}' ;;
        'dns records list') jq -c . "$CF_TEST_STATE" ;;
        'dns records create'|'dns records edit')
            local operation="$3" body
            [[ "${*: -1}" != --dry-run ]] || return 0
            body="${*: -1}"
            if [[ "$operation" == create ]]; then
                jq -cn --argjson body "$body" '[$body + {id:"record"}]' >"$CF_TEST_STATE"
            else
                [[ "$4" == record && "$body" == '{"proxied":true}' ]] || return 1
                local updated
                updated="$(jq -c '.[0].proxied = true' "$CF_TEST_STATE")"
                printf '%s\n' "$updated" >"$CF_TEST_STATE"
            fi
            jq '.[0]' "$CF_TEST_STATE"
            ;;
        *) return 1 ;;
    esac
}

curl() {
    [[ "$CF_TEST_TLS" == yes && " $* " == *' --resolve split.example.com:443:192.0.2.42 '* ]]
}
export -f cf curl
dns() { bash "$ROOT/tools/cf-xhttp-dns.sh" "$1" example.com split.example.com "${2:-192.0.2.42}"; }
fails() {
    if "$@" >/dev/null 2>&1; then
        echo "unexpected success: $*" >&2
        exit 1
    fi
}
fails dns proxy
dns prepare
dns prepare
fails dns prepare 192.0.2.5
CF_TEST_TLS=no fails dns proxy
CF_TEST_SSL=full fails dns proxy
jq -e 'length == 1 and .[0].proxied == false' "$state" >/dev/null
dns proxy
dns proxy
dns prepare
jq -e 'length == 1 and .[0].proxied == true' "$state" >/dev/null
echo 'cf-xhttp-dns: idempotent prepare/proxy and conflict/TLS checks passed'
