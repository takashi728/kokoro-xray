#!/usr/bin/env bash
# kokoro-xray — geodata install and update

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

KOKORO_XRAY_VERSION="${KOKORO_XRAY_VERSION:-v26.11.9}"
KOKORO_XRAY_SHA256_AMD64="b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82"
KOKORO_XRAY_SHA256_ARM64="64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be"

kokoro_xray_release_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        *) kokoro_die "unsupported arch: $arch" ;;
    esac
    printf '%s\n' "$arch"
}

kokoro_xray_release_zip() {
    printf 'Xray-linux-%s.zip\n' "$(kokoro_xray_release_arch)"
}

kokoro_xray_sha256() { # version arch
    [[ "$1" == "$KOKORO_XRAY_VERSION" ]] || return 1
    case "$2" in
        64) printf '%s\n' "$KOKORO_XRAY_SHA256_AMD64" ;;
        arm64-v8a) printf '%s\n' "$KOKORO_XRAY_SHA256_ARM64" ;;
        *) return 1 ;;
    esac
}

kokoro_xray_verify_zip() {
    local zip_path="$1" expected="$2"
    printf '%s  %s\n' "$expected" "$zip_path" | sha256sum -c - >/dev/null
}

kokoro_xray_download_release_zip() {
    local tmp="$1" zip arch expected base_url
    zip="$(kokoro_xray_release_zip)"
    expected="$(kokoro_xray_sha256 "$KOKORO_XRAY_VERSION" "$(kokoro_xray_release_arch)")" ||
        kokoro_die "no pinned SHA-256 for $KOKORO_XRAY_VERSION/$(kokoro_xray_release_arch)"
    base_url="https://github.com/XTLS/Xray-core/releases/download/${KOKORO_XRAY_VERSION}"
    curl --proto '=https' --proto-redir '=https' -fsSL "${base_url}/${zip}" -o "${tmp}/${zip}" || return 1
    kokoro_xray_verify_zip "${tmp}/${zip}" "$expected" || return 1
    printf '%s\n' "$zip"
}

kokoro_geodata_install() {
    local geo_dir zip tmp
    kokoro_validate_service_paths
    geo_dir="$(kokoro_cfg '.paths.geo_dir')"
    tmp="$(mktemp -d)"
    zip="$(kokoro_xray_download_release_zip "$tmp")" && unzip -qo "${tmp}/${zip}" -d "$tmp" ||
        { rm -rf -- "$tmp"; kokoro_die "failed to obtain verified Xray geodata"; }
    install -d "$geo_dir"
    install -m 644 "${tmp}/geoip.dat" "${tmp}/geosite.dat" "$geo_dir/"
    rm -rf "$tmp"
    kokoro_log "geodata installed to ${geo_dir}"
}

kokoro_geodata_update() {
    kokoro_need_root
    kokoro_validate_service_paths
    kokoro_geodata_install
}
