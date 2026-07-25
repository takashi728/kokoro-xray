#!/usr/bin/env bash
# kokoro-xray — shared constants and helpers

[[ -n "${KOKORO_COMMON_LOADED:-}" ]] && return 0
KOKORO_COMMON_LOADED=1

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly RED='\033[31m'
readonly CYAN='\033[36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

readonly KOKORO_HOME="${HOME}/.kokoro-xray"
readonly KOKORO_CONFIG="${KOKORO_HOME}/config.json"
readonly KOKORO_SECRETS="${KOKORO_HOME}/secrets.json"
readonly KOKORO_LAST_GOOD="${KOKORO_HOME}/last-good"

# Set by kokoro-xray.sh entrypoint; fallback for direct lib sourcing
: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export KOKORO_ROOT

kokoro_ensure_state() {
    install -d -m 700 "${KOKORO_HOME}"
    install -d -m 700 "${KOKORO_LAST_GOOD}"
    if [[ -f "${KOKORO_CONFIG}" ]] && { [[ ! -s "${KOKORO_CONFIG}" ]] || ! jq -e type "${KOKORO_CONFIG}" >/dev/null 2>&1; }; then
        mv "${KOKORO_CONFIG}" "${KOKORO_CONFIG}.broken.$(date +%s)"
    fi
    if [[ ! -f "${KOKORO_CONFIG}" ]]; then
        cp "${KOKORO_ROOT}/config.defaults.json" "${KOKORO_CONFIG}"
        chmod 644 "${KOKORO_CONFIG}"
    fi
    if [[ -f "${KOKORO_SECRETS}" ]] && { [[ ! -s "${KOKORO_SECRETS}" ]] || ! jq -e type "${KOKORO_SECRETS}" >/dev/null 2>&1; }; then
        mv "${KOKORO_SECRETS}" "${KOKORO_SECRETS}.broken.$(date +%s)"
    fi
    if [[ ! -f "${KOKORO_SECRETS}" ]]; then
        cp "${KOKORO_ROOT}/secrets.defaults.json" "${KOKORO_SECRETS}"
        chmod 600 "${KOKORO_SECRETS}"
    fi
    if [[ -f "${KOKORO_ROOT}/lib/migrate.sh" ]]; then
        # shellcheck source=lib/migrate.sh
        source "${KOKORO_ROOT}/lib/migrate.sh"
        kokoro_migrate 2>/dev/null || true
    fi
}

kokoro_ensure_config() { kokoro_ensure_state; }

kokoro_check_secret_perms() {
    local perms
    perms="$(stat -c '%a' "${KOKORO_SECRETS}" 2>/dev/null || echo '')"
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        kokoro_warn "secrets.json should be mode 600 (got ${perms:-unknown})"
        chmod 600 "${KOKORO_SECRETS}" 2>/dev/null || true
    fi
}

kokoro_cfg() {
    jq -r "$1" "${KOKORO_CONFIG}"
}

kokoro_cfg_set() {
    local tmp
    tmp="$(mktemp)"
    jq "$1 = $2" "${KOKORO_CONFIG}" >"$tmp"
    mv "$tmp" "${KOKORO_CONFIG}"
}

kokoro_cfg_set_str() {
    local tmp
    tmp="$(mktemp)"
    jq --arg v "$2" "$1 = \$v" "${KOKORO_CONFIG}" >"$tmp"
    mv "$tmp" "${KOKORO_CONFIG}"
}

kokoro_sec() {
    jq -r "$1" "${KOKORO_SECRETS}"
}

kokoro_sec_set_str() {
    local tmp
    tmp="$(mktemp)"
    jq --arg v "$2" "$1 = \$v" "${KOKORO_SECRETS}" >"$tmp"
    mv "$tmp" "${KOKORO_SECRETS}"
    chmod 600 "${KOKORO_SECRETS}"
}

kokoro_sec_set() {
    local tmp
    tmp="$(mktemp)"
    jq "$1 = $2" "${KOKORO_SECRETS}" >"$tmp"
    mv "$tmp" "${KOKORO_SECRETS}"
    chmod 600 "${KOKORO_SECRETS}"
}

kokoro_log() { echo -e "${GREEN}[kokoro]${NC} $*"; }
kokoro_warn() { echo -e "${YELLOW}[warn]${NC} $*" >&2; }
kokoro_die() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

kokoro_need_root() {
    [[ "${EUID}" -eq 0 ]] || kokoro_die "run as root"
}

kokoro_need_cmd() {
    command -v "$1" >/dev/null 2>&1 || kokoro_die "missing command: $1"
}

kokoro_caddy_required() {
    local mode
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "tls" || "$mode" == "both" ]]
}

kokoro_load_i18n() {
    local lang file
    lang="$(kokoro_cfg '.language')"
    if [[ "$lang" == "auto" || -z "$lang" || "$lang" == "null" ]]; then
        lang="${LANG%%_*}"
        lang="${lang:-en}"
    fi
    file="${KOKORO_ROOT}/i18n/${lang}.json"
    [[ -f "$file" ]] || file="${KOKORO_ROOT}/i18n/en.json"
    [[ -f "$file" ]] || kokoro_die "i18n file not found"
    KOKORO_I18N_FILE="$file"
}

kokoro_t() {
    jq -r --arg k "$1" '.[$k] // $k' "${KOKORO_I18N_FILE}"
}

# Backward compat shim (removed in v0.2)
kokoro_project_root() { printf '%s\n' "${KOKORO_ROOT}"; }
