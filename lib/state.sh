#!/usr/bin/env bash
# kokoro-xray — core/state: load config+secrets once per process
#
# Reads both JSON state files a single time and flattens every scalar leaf
# into KOKORO_CFG_<PATH> / KOKORO_SEC_<PATH> shell variables, so hot paths
# (status/apply/onboard/link) stop spawning one jq per read.
#
# Non-scalar paths (arrays) and paths without a flattened variable fall back
# to jq — semantics match the old file-read behavior.

kokoro_state_var_suffix() {
    local p="$1"
    p="${p#.}"
    p="${p//./_}"
    p="${p//[/_}"
    p="${p//]/}"
    printf '%s' "${p^^}"
}

kokoro_state_flatten() { # prefix json -> eval-safe VAR=val lines
    local prefix="$1" json="$2"
    jq -r --arg prefix "$prefix" '
        paths(scalars) as $p
        | ($prefix + "_" + ($p | map(tostring | ascii_upcase | gsub("[^A-Z0-9_]"; "_")) | join("_")))
          + "=" + (getpath($p) | @sh)
    ' <<<"$json"
}

kokoro_state_unset() {
    unset -v _KOKORO_RAW_CFG_JSON _KOKORO_RAW_SEC_JSON "${!KOKORO_CFG_@}" "${!KOKORO_SEC_@}"
}

kokoro_state_refresh_cfg() {
    local json assignments
    json="$(cat -- "$KOKORO_CONFIG")" || return 1
    assignments="$(kokoro_state_flatten KOKORO_CFG "$json")" || return 1
    unset -v "${!KOKORO_CFG_@}"
    _KOKORO_RAW_CFG_JSON="$json"
    eval "$assignments"
}

kokoro_state_refresh_sec() {
    local json assignments
    json="$(cat -- "$KOKORO_SECRETS")" || return 1
    assignments="$(kokoro_state_flatten KOKORO_SEC "$json")" || return 1
    unset -v "${!KOKORO_SEC_@}"
    _KOKORO_RAW_SEC_JSON="$json"
    eval "$assignments"
}

kokoro_state_refresh() {
    kokoro_state_refresh_cfg || return 1
    kokoro_state_refresh_sec
}

kokoro_cfg() {
    local path="$1" name
    name="KOKORO_CFG_$(kokoro_state_var_suffix "$path")"
    if [[ -v "$name" ]]; then
        printf '%s' "${!name}"
    elif [[ -v _KOKORO_RAW_CFG_JSON ]]; then
        jq -r "$path" <<<"${_KOKORO_RAW_CFG_JSON}"
    else
        jq -r "$path" "${KOKORO_CONFIG}"
    fi
}

kokoro_sec() {
    local path="$1" name
    name="KOKORO_SEC_$(kokoro_state_var_suffix "$path")"
    if [[ -v "$name" ]]; then
        printf '%s' "${!name}"
    elif [[ -v _KOKORO_RAW_SEC_JSON ]]; then
        jq -r "$path" <<<"${_KOKORO_RAW_SEC_JSON}"
    else
        jq -r "$path" "${KOKORO_SECRETS}"
    fi
}

kokoro_write_private() (
    local destination="$1" staged cleanup
    shift
    staged="$(mktemp -- "${destination}.XXXXXX")" || return 1
    printf -v cleanup 'rm -f -- %q' "$staged"
    trap "$cleanup" EXIT
    trap 'exit 1' HUP INT TERM
    chmod 600 -- "$staged" || return 1
    "$@" >"$staged" || return 1
    mv -fT -- "$staged" "$destination" || return 1
    trap - EXIT
)

kokoro_cfg_set() {
    kokoro_write_private "$KOKORO_CONFIG" jq "$1 = $2" "$KOKORO_CONFIG" || return 1
    chmod 644 "$KOKORO_CONFIG" || return 1
    kokoro_state_refresh_cfg
}

kokoro_cfg_set_str() {
    kokoro_write_private "$KOKORO_CONFIG" jq --arg v "$2" "$1 = \$v" "$KOKORO_CONFIG" || return 1
    chmod 644 "$KOKORO_CONFIG" || return 1
    kokoro_state_refresh_cfg
}

kokoro_sec_set_str() {
    kokoro_write_private "$KOKORO_SECRETS" jq --arg v "$2" "$1 = \$v" "$KOKORO_SECRETS" || return 1
    kokoro_state_refresh_sec
}

kokoro_sec_set() {
    kokoro_write_private "$KOKORO_SECRETS" jq "$1 = $2" "$KOKORO_SECRETS" || return 1
    kokoro_state_refresh_sec
}
