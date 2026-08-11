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
    local v
    for v in "${!KOKORO_CFG_@}" "${!KOKORO_SEC_@}"; do
        unset "$v" 2>/dev/null || true
    done
}

kokoro_state_refresh_cfg() {
    KOKORO_CFG_JSON="$(cat "${KOKORO_CONFIG}")"
    eval "$(kokoro_state_flatten KOKORO_CFG "${KOKORO_CFG_JSON}")"
}

kokoro_state_refresh_sec() {
    KOKORO_SEC_JSON="$(cat "${KOKORO_SECRETS}")"
    eval "$(kokoro_state_flatten KOKORO_SEC "${KOKORO_SEC_JSON}")"
}

kokoro_state_refresh() {
    kokoro_state_unset
    kokoro_state_refresh_cfg
    kokoro_state_refresh_sec
}

kokoro_cfg() {
    local path="$1" name
    name="KOKORO_CFG_$(kokoro_state_var_suffix "$path")"
    if [[ -v "$name" ]]; then
        printf '%s' "${!name}"
    elif [[ -v KOKORO_CFG_JSON ]]; then
        jq -r "$path" <<<"${KOKORO_CFG_JSON}"
    else
        jq -r "$path" "${KOKORO_CONFIG}"
    fi
}

kokoro_sec() {
    local path="$1" name
    name="KOKORO_SEC_$(kokoro_state_var_suffix "$path")"
    if [[ -v "$name" ]]; then
        printf '%s' "${!name}"
    elif [[ -v KOKORO_SEC_JSON ]]; then
        jq -r "$path" <<<"${KOKORO_SEC_JSON}"
    else
        jq -r "$path" "${KOKORO_SECRETS}"
    fi
}

kokoro_cfg_set() {
    local tmp
    tmp="$(mktemp)"
    jq "$1 = $2" "${KOKORO_CONFIG}" >"$tmp"
    mv "$tmp" "${KOKORO_CONFIG}"
    kokoro_state_refresh_cfg
}

kokoro_cfg_set_str() {
    local tmp
    tmp="$(mktemp)"
    jq --arg v "$2" "$1 = \$v" "${KOKORO_CONFIG}" >"$tmp"
    mv "$tmp" "${KOKORO_CONFIG}"
    kokoro_state_refresh_cfg
}

kokoro_sec_set_str() {
    local tmp
    tmp="$(mktemp)"
    jq --arg v "$2" "$1 = \$v" "${KOKORO_SECRETS}" >"$tmp"
    mv "$tmp" "${KOKORO_SECRETS}"
    chmod 600 "${KOKORO_SECRETS}"
    kokoro_state_refresh_sec
}

kokoro_sec_set() {
    local tmp
    tmp="$(mktemp)"
    jq "$1 = $2" "${KOKORO_SECRETS}" >"$tmp"
    mv "$tmp" "${KOKORO_SECRETS}"
    chmod 600 "${KOKORO_SECRETS}"
    kokoro_state_refresh_sec
}
