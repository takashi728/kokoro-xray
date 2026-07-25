#!/usr/bin/env bash
# kokoro-xray — OS detection and package helpers

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        KOKORO_OS_ID="${ID:-unknown}"
        KOKORO_OS_VER="${VERSION_ID:-}"
    else
        KOKORO_OS_ID="unknown"
        KOKORO_OS_VER=""
    fi
}

kokoro_os_supported() {
    kokoro_detect_os
    case "${KOKORO_OS_ID}" in
        debian | ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

kokoro_pkg_install() {
    kokoro_detect_os
    kokoro_need_root
    case "${KOKORO_OS_ID}" in
        debian | ubuntu)
            apt-get -o DPkg::Lock::Timeout=120 update -qq
            DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
                apt-get -o DPkg::Lock::Timeout=120 install -y -qq "$@"
            ;;
        *)
            kokoro_die "unsupported OS: ${KOKORO_OS_ID}"
            ;;
    esac
}

kokoro_install_deps() {
    local package
    local -a packages=(
        ca-certificates curl git jq openssl tar unzip
        uuid-runtime wireguard-tools ufw
    )
    local -a missing=()

    kokoro_os_supported || kokoro_die "only Debian/Ubuntu supported for now"
    for package in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
            grep -q 'ok installed' || missing+=("$package")
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        kokoro_log "dependencies already installed"
        return 0
    fi

    kokoro_log "installing dependencies: ${missing[*]}"
    kokoro_pkg_install "${missing[@]}"
}
