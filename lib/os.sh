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
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
            ;;
        *)
            kokoro_die "unsupported OS: ${KOKORO_OS_ID}"
            ;;
    esac
}

kokoro_install_deps() {
    kokoro_os_supported || kokoro_die "only Debian/Ubuntu supported for now"
    kokoro_pkg_install curl jq ca-certificates unzip ufw
}
