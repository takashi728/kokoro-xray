#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/../.." && pwd -P)"
export KOKORO_ROOT="$ROOT"

source "${ROOT}/lib/os.sh"

kokoro_os_supported() { return 0; }
dpkg-query() {
    case "${!#}" in
        jq | uuid-runtime) return 1 ;;
        *) printf 'install ok installed\n' ;;
    esac
}
kokoro_pkg_install() {
    [[ "$*" == "jq uuid-runtime" ]]
}

kokoro_install_deps >/dev/null

line_of() {
    local pattern="$1" file="$2"
    awk -v pattern="$pattern" 'index($0, pattern) { print NR; exit }' "$file"
}

line_exact() {
    local text="$1" file="$2"
    awk -v text="$text" '$0 == text { print NR; exit }' "$file"
}

for role in edge exit; do
    dep_line="$(line_of '    kokoro_install_deps' "${ROOT}/roles/${role}.sh")"
    onboard_line="$(line_of '    kokoro_onboard_' "${ROOT}/roles/${role}.sh")"
    [[ "$dep_line" -lt "$onboard_line" ]]
done

bootstrap_line="$(line_exact 'install_bootstrap_deps' "${ROOT}/install.sh")"
install_line="$(line_exact 'if [[ -n "$REPO_BRANCH" ]]; then' "${ROOT}/install.sh")"
[[ "$bootstrap_line" -lt "$install_line" ]]

for package in jq openssl uuid-runtime wireguard-tools ufw; do
    grep -q "$package" "${ROOT}/install.sh"
    grep -q "$package" "${ROOT}/lib/os.sh"
done

echo "os-test OK"
