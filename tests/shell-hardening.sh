#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export HOME="$TMP" KOKORO_ROOT="$ROOT"

source "$ROOT/lib/keys.sh"
source "$ROOT/lib/caddy.sh"

test_cache() (
    kokoro_ensure_state
    [[ "$(kokoro_cfg '.json')" == null && "$(kokoro_sec '.json')" == null ]]
    kokoro_cfg_set_str '.json' 'config scalar'
    kokoro_sec_set_str '.json' 'secret scalar'
    [[ "$(kokoro_cfg '.json')" == 'config scalar' && "$(kokoro_sec '.json')" == 'secret scalar' ]]
    [[ "$(kokoro_cfg '.inbound.reality.server_names | first')" == www.cloudflare.com ]]
    [[ "$(kokoro_sec '.inbound | .xhttp_path')" == "" ]]
    kokoro_sec_set '.json' '["replacement"]'
    [[ "$(kokoro_sec '.json' | jq -r 'first')" == replacement ]]
    kokoro_state_unset
    [[ ! -v _KOKORO_RAW_CFG_JSON && ! -v _KOKORO_RAW_SEC_JSON ]]
)

test_pair() (
    local fixture="$TMP/pair" output
    mkdir -p "$fixture"/{roles,lib}
    cp "$ROOT/roles/pair.sh" "$fixture/roles/"
    cat >"$fixture/lib/common.sh" <<'STUB'
kokoro_ensure_state() { :; }
kokoro_cfg() { echo exit; }
kokoro_cfg_set_str() { :; }
kokoro_sec() { echo test-key; }
kokoro_warn() { echo "$*" >&2; }
curl() {
    printf '%s\n' "$@" >"$HOME/curl.args"
    printf '%s\n' "$REMOTE_ADDR"
    return "$CURL_STATUS"
}
hostname() {
    [[ "$1" == -I ]] || return 1
    printf '%s\n' "$LOCAL_ADDRS"
}
STUB
    echo 'kokoro_apply() { :; }' >"$fixture/lib/apply.sh"
    run_pair() { bash -eu "$fixture/roles/pair.sh" <<< 'peer-key'; }
    export REMOTE_ADDR=203.0.113.255 LOCAL_ADDRS='2001:db8::1 192.0.2.1' CURL_STATUS=0
    output="$(run_pair)"
    grep -Fxq 'exit_ip=203.0.113.255' <<<"$output"
    local args
    args="$(paste -sd ' ' "$HOME/curl.args")"
    [[ " $args " == *' -4 '* ]]
    [[ " $args " == *' --proto =https '* && " $args " == *' --proto-redir =https '* ]]
    [[ " $args " == *' --max-time 5 '* && " $args " == *' https://ifconfig.me '* ]]
    for REMOTE_ADDR in '256.0.0.1' '2001:db8::1' $'203.0.113.1\nextra' ''; do
        output="$(run_pair)"
        grep -Fxq 'exit_ip=192.0.2.1' <<<"$output"
    done
    REMOTE_ADDR=203.0.113.8 CURL_STATUS=1
    output="$(run_pair)"
    grep -Fxq 'exit_ip=192.0.2.1' <<<"$output"
    LOCAL_ADDRS='2001:db8::1 999.1.2.3'
    output="$(run_pair 2>"$TMP/pair.err")"
    [[ "$output" != *exit_ip=* && -s "$TMP/pair.err" ]]
)

test_caddy() (
    local target="$TMP/caddy 'binary'" mode
    kokoro_need_root() { :; }
    kokoro_validate_service_paths() { :; }
    kokoro_cfg() { echo "$target"; }
    kokoro_caddy_version() { echo v1; }
    kokoro_small_vps() { [[ "$mode" == download ]]; }
    kokoro_caddy_download() { return 1; }
    kokoro_caddy_build() { echo binary >"$2"; [[ "$mode" != build ]]; }
    kokoro_caddy_installed_matches() {
        if [[ "$1" == "$target" ]]; then [[ "$mode" == installed ]]
        else [[ "$mode" != mismatch ]]; fi
    }
    mv() { [[ "$mode" != move ]] && command mv "$@"; }
    kokoro_caddy_install_service() { [[ "$mode" != service ]]; }
    for mode in download build mismatch move service success installed; do
        if kokoro_caddy_install >/dev/null 2>"$TMP/caddy.err"; then
            [[ "$mode" == success || "$mode" == installed ]]
        else
            [[ "$mode" != success && "$mode" != installed ]]
        fi
        if compgen -G "$target.new.*" >/dev/null; then return 1; fi
        if grep -q 'unbound variable' "$TMP/caddy.err"; then return 1; fi
        if [[ "$mode" == service || "$mode" == success || "$mode" == installed ]]; then
            [[ -x "$target" && "$(cat "$target")" == binary ]]
        else
            [[ ! -e "$target" ]]
        fi
    done
)

test_cache
test_pair
test_caddy
echo 'shell-hardening-test OK'
