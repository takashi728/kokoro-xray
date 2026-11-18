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

readonly KOKORO_CANONICAL_XRAY_BIN="/usr/local/bin/xray"
readonly KOKORO_CANONICAL_XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly KOKORO_CANONICAL_CADDY_BIN="/usr/local/bin/caddy"
readonly KOKORO_CANONICAL_CADDYFILE="/etc/caddy/Caddyfile"
readonly KOKORO_CANONICAL_GEO_DIR="/usr/local/share/xray"
readonly KOKORO_CANONICAL_HYSTERIA_CERT_ROOT="/var/lib/kokoro-caddy/certificates"

# Set by kokoro-xray.sh entrypoint; fallback for direct lib sourcing
: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export KOKORO_ROOT

source "${KOKORO_ROOT}/lib/state.sh"

kokoro_path_is_systemd_safe() { # path
    local path="$1"
    [[ -n "$path" && "$path" != "null" ]] || return 1
    [[ "${#path}" -le 4096 ]] || return 1
    [[ "$path" == /* ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
    [[ "$path" != *" "* && "$path" != *'"'* && "$path" != *"'"* ]] || return 1
    [[ "$path" != *'\'* && "$path" != *'%'* ]] || return 1
    [[ "$path" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]
}

kokoro_require_safe_path() { # label path
    local label="$1" path="$2" canonical
    kokoro_path_is_systemd_safe "$path" ||
        kokoro_die "unsafe ${label} path: ${path}"
    canonical="$(realpath -m -- "$path")" ||
        kokoro_die "cannot canonicalize ${label} path: ${path}"
    [[ "$canonical" == "$path" ]] ||
        kokoro_die "non-canonical ${label} path: ${path}"
}

kokoro_path_test_allowed() { # path
    local root="${KOKORO_TEST_PATH_ROOT:-}" canonical
    [[ "${EUID}" -ne 0 && -n "$root" && "$root" == /* ]] || return 1
    canonical="$(realpath -m -- "$root")" || return 1
    [[ "$1" == "${canonical}/"* ]]
}

kokoro_require_service_path() { # config-key label canonical
    local key="$1" label="$2" canonical="$3" value
    value="$(kokoro_cfg "$key")"
    kokoro_require_safe_path "$key" "$value"
    if [[ "${EUID}" -ne 0 ]] && kokoro_path_test_allowed "$value"; then
        return 0
    fi
    [[ "$value" == "$canonical" ]] ||
        kokoro_die "${key} must be the canonical ${label}: ${canonical}"
}

kokoro_hysteria_cert_root() {
    if [[ "${EUID}" -ne 0 && "${KOKORO_TEST_HYSTERIA_CERT_ROOT:-}" == /* ]]; then
        printf '%s\n' "$KOKORO_TEST_HYSTERIA_CERT_ROOT"
    else
        printf '%s\n' "$KOKORO_CANONICAL_HYSTERIA_CERT_ROOT"
    fi
}

kokoro_require_hysteria_file() { # config-key suffix; shared by HY2 and RAW TLS
    local key="$1" suffix="$2" path root canonical uid mode test_root=""
    local root_uid root_mode
    if [[ "${EUID}" -ne 0 ]]; then
        test_root="${KOKORO_TEST_HYSTERIA_CERT_ROOT:-}"
    fi
    path="$(kokoro_cfg "$key")"
    kokoro_require_safe_path "$key" "$path"
    [[ -f "$path" && ! -L "$path" ]] ||
        kokoro_die "missing regular ${key} file: ${path}"
    canonical="$(realpath -e -- "$path")" ||
        kokoro_die "cannot resolve ${key}: ${path}"
    if [[ -n "$test_root" ]]; then
        root="$(realpath -m -- "$test_root")"
    else
        root="$(kokoro_hysteria_cert_root)"
    fi
    [[ "$canonical" == "${root}/"* && "$canonical" != "$root" ]] ||
        kokoro_die "${key} must stay inside ${root}: ${path}"
    [[ "$canonical" == *"${suffix}" ]] ||
        kokoro_die "${key} must end with ${suffix}: ${path}"

    if [[ -z "$test_root" ]]; then
        [[ -d "$root" && ! -L "$root" ]] ||
            kokoro_die "managed certificate root is not a directory: ${root}"
        root_uid="$(stat -c '%u' "$root")"
        root_mode="$(stat -c '%a' "$root")"
        [[ "$root_uid" == "0" ]] ||
            kokoro_die "managed certificate root must be owned by root: ${root}"
        (( (8#${root_mode} & 8#022) == 0 )) ||
            kokoro_die "managed certificate root must not be group/world writable: ${root}"
        uid="$(stat -c '%u' "$canonical")"
        mode="$(stat -c '%a' "$canonical")"
        [[ "$uid" == "0" ]] || kokoro_die "${key} must be owned by root: ${path}"
        (( (8#${mode} & 8#022) == 0 )) ||
            kokoro_die "${key} must not be group/world writable: ${path}"
    fi
}

kokoro_validate_service_paths() {
    kokoro_require_service_path '.paths.xray_bin' 'Xray executable' "$KOKORO_CANONICAL_XRAY_BIN"
    kokoro_require_service_path '.paths.xray_config' 'Xray config' "$KOKORO_CANONICAL_XRAY_CONFIG"
    kokoro_require_service_path '.paths.caddy_bin' 'Caddy executable' "$KOKORO_CANONICAL_CADDY_BIN"
    kokoro_require_service_path '.paths.caddyfile' 'Caddy config' "$KOKORO_CANONICAL_CADDYFILE"
    kokoro_require_service_path '.paths.geo_dir' 'geodata directory' "$KOKORO_CANONICAL_GEO_DIR"
}

kokoro_systemd_unit_dir() {
    if [[ "${EUID}" -ne 0 && -n "${KOKORO_TEST_SYSTEMD_UNIT_DIR:-}" ]]; then
        printf '%s\n' "$KOKORO_TEST_SYSTEMD_UNIT_DIR"
    else
        printf '/etc/systemd/system\n'
    fi
}

kokoro_verify_systemd_unit() { # file
    command -v systemd-analyze >/dev/null 2>&1 ||
        kokoro_die "systemd-analyze is required to verify service units"
    local output
    if output="$(systemd-analyze verify "$1" 2>&1)"; then
        return 0
    fi
    # Unprivileged containerized verify can fail after parsing because it
    # cannot create its user-lookup socket. Treat only that known host failure
    # as non-fatal; any unit diagnostic still fails closed.
    if [[ "$output" != *"SO_PASSRIGHTS"* && "$output" != *"SO_PASSCRED"* ]]; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    if grep -Ev 'SO_PASSRIGHTS|SO_PASSCRED' <<<"$output" | grep -q .; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    return 0
}

kokoro_install_systemd_unit() { # name content
    local name="$1" content="$2" unit_dir tmp
    [[ "$name" =~ ^[A-Za-z0-9_.@-]+\.(service|path)$ ]] ||
        kokoro_die "invalid systemd unit name: ${name}"
    unit_dir="$(kokoro_systemd_unit_dir)"
    install -d -m 755 "$unit_dir"
    tmp="$(mktemp -d)"
    printf '%s\n' "$content" >"${tmp}/${name}"
    if ! kokoro_verify_systemd_unit "${tmp}/${name}"; then
        rm -rf "$tmp"
        kokoro_die "generated systemd unit failed verification: ${name}"
    fi
    install -m 644 "${tmp}/${name}" "${unit_dir}/${name}"
    rm -rf "$tmp"
}

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
    kokoro_state_refresh
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

kokoro_log() { echo -e "${GREEN}[kokoro]${NC} $*"; }
kokoro_warn() { echo -e "${YELLOW}[warn]${NC} $*" >&2; }
kokoro_die() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

kokoro_need_root() {
    [[ "${EUID}" -eq 0 ]] || kokoro_die "run as root"
}

kokoro_need_cmd() {
    command -v "$1" >/dev/null 2>&1 || kokoro_die "missing command: $1"
}

kokoro_raw_tls_enabled() {
    [[ "$(kokoro_cfg '.role')" == edge && "$(kokoro_cfg '.inbound.transport // "xhttp"')" == raw &&
       "$(kokoro_cfg '.inbound.mode')" =~ ^(tls|both)$ ]]
}

kokoro_tls_domain() {
    if kokoro_raw_tls_enabled; then kokoro_cfg '.inbound.tls.domain'
    else kokoro_cfg '.inbound.tls.cdn_domain'; fi
}

kokoro_caddy_required() {
    local mode
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "tls" || "$mode" == "both" ||
       "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]]
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
