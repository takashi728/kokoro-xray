#!/usr/bin/env bash

source "${KOKORO_ROOT}/lib/common.sh"

kokoro_cf_text() {
    [[ -n ${KOKORO_I18N_FILE:-} ]] || kokoro_load_i18n
    jq -r --arg key "$1" --slurpfile fallback "$KOKORO_ROOT/i18n/en.json" \
        '.[$key] // $fallback[0][$key] // $key' "$KOKORO_I18N_FILE"
}

kokoro_cf_domain() {
    [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

kokoro_cf_ip() {
    if [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        ip -4 route show match "$1/32" >/dev/null 2>&1
    elif [[ $1 == *:* && $1 =~ ^[a-fA-F0-9:]+$ ]]; then
        ip -6 route show match "$1/128" >/dev/null 2>&1
    else return 1; fi
}

kokoro_cf_host() { kokoro_cf_domain "$1" || kokoro_cf_ip "$1"; }

kokoro_cf_validate() {
    local toggle
    for toggle in warp argo; do
        case "$(kokoro_cfg "(.${toggle}.enabled // false) | type")" in
            boolean) ;;
            *) kokoro_warn "$(kokoro_cf_text cf_invalid)"; return 1 ;;
        esac
    done
    if [[ $(kokoro_cfg '.warp.enabled // false') == true ]]; then
        source "${KOKORO_ROOT}/lib/warp.sh"
        kokoro_warp_validate || return 1
    fi
    if [[ $(kokoro_cfg '.argo.enabled // false') == true ]]; then
        source "${KOKORO_ROOT}/lib/argo.sh"
        kokoro_argo_validate || return 1
    fi
}

kokoro_cf_secret() {
    kokoro_write_private "$KOKORO_SECRETS" jq --rawfile value /dev/stdin \
        "$1 = (\$value | rtrimstr(\"\\n\"))" "$KOKORO_SECRETS" || return 1
    kokoro_state_refresh_sec
}

kokoro_cf_prompt() {
    local answer
    read -r -p "$(kokoro_cf_text "$1") [$2]: " answer || return 1
    printf '%s' "${answer:-$2}"
}

kokoro_cf_run() (
    set -euo pipefail
    local feature="$1" action="${2:-status}"
    shift
    if (( $# )); then shift; fi
    case "$feature" in
        warp) source "${KOKORO_ROOT}/lib/warp.sh" ;;
        argo) source "${KOKORO_ROOT}/lib/argo.sh" ;;
        *) return 2 ;;
    esac
    case "$feature/$action" in
        */status) "kokoro_${feature}_status"; return ;;
        warp/test) kokoro_warp_test "$@"; return ;;
        warp/fetch-pubkey|*/setup|*/on|*/off|argo/uninstall) ;;
        *) kokoro_die "$(kokoro_cf_text cf_usage)" ;;
    esac
    kokoro_need_root
    exec 9>"$KOKORO_HOME/cloudflare.lock"
    flock -x 9
    kokoro_state_refresh
    cf_applying=false
    cf_backup="$(mktemp -d "$KOKORO_HOME/cf-state.XXXXXXXX")"
    cp -p -- "$KOKORO_CONFIG" "$cf_backup/config"
    cp -p -- "$KOKORO_SECRETS" "$cf_backup/secrets"
    # shellcheck disable=SC2329
    kokoro_cf_finish() {
        local result=$?
        trap - EXIT
        if (( result != 0 )); then
            mv -fT -- "$cf_backup/config" "$KOKORO_CONFIG"
            mv -fT -- "$cf_backup/secrets" "$KOKORO_SECRETS"
            if [[ $cf_applying == true ]]; then
                bash "$KOKORO_ROOT/kokoro-xray.sh" apply ||
                    kokoro_warn "$(kokoro_cf_text cf_recover)"
            fi
        fi
        rm -rf -- "$cf_backup"
        exit "$result"
    }
    trap kokoro_cf_finish EXIT
    trap 'exit 1' INT TERM HUP
    case "$action" in
        setup) "kokoro_${feature}_setup" "$@" ;;
        on|off|uninstall)
            [[ $# == 0 ]] || kokoro_die "$(kokoro_cf_text cf_usage)"
            if [[ $action == on ]]; then kokoro_cfg_set ".$feature.enabled" true
            else kokoro_cfg_set ".$feature.enabled" false; fi
            if [[ $action == uninstall ]]; then kokoro_cf_secret '.argo.tunnel_token' </dev/null; fi ;;
        fetch-pubkey) kokoro_warp_refresh "$@" ;;
    esac
    if [[ $action == fetch-pubkey && $(kokoro_cfg '.warp.enabled') != true ]]; then return 0; fi
    kokoro_validate_service_paths
    kokoro_cf_validate
    cf_applying=true
    bash "$KOKORO_ROOT/kokoro-xray.sh" apply
)
