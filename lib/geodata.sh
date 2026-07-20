#!/usr/bin/env bash
# kokoro-xray — geodata install and update

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

KOKORO_XRAY_VERSION="${KOKORO_XRAY_VERSION:-v26.7.11}"

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

kokoro_xray_verify_zip() {
    local zip_path="$1" dgst_path="$2" expected
    expected="$(awk -F'= *' '$1 == "SHA2-256" { gsub(/[[:space:]\r]/, "", $2); print $2; exit }' "$dgst_path")"
    [[ -n "$expected" ]] || kokoro_die "SHA2-256 not found in $(basename "$dgst_path")"
    printf '%s  %s\n' "$expected" "$zip_path" | sha256sum -c - >/dev/null
}

kokoro_xray_download_release_zip() {
    local tmp="$1" zip base_url
    zip="$(kokoro_xray_release_zip)"
    base_url="https://github.com/XTLS/Xray-core/releases/download/${KOKORO_XRAY_VERSION}"
    curl -fsSL "${base_url}/${zip}" -o "${tmp}/${zip}"
    curl -fsSL "${base_url}/${zip}.dgst" -o "${tmp}/${zip}.dgst"
    kokoro_xray_verify_zip "${tmp}/${zip}" "${tmp}/${zip}.dgst"
    printf '%s\n' "$zip"
}

kokoro_geodata_install() {
    local geo_dir zip tmp
    geo_dir="$(kokoro_cfg '.paths.geo_dir')"
    tmp="$(mktemp -d)"
    zip="$(kokoro_xray_download_release_zip "$tmp")"
    unzip -qo "${tmp}/${zip}" -d "$tmp"
    install -d "$geo_dir"
    install -m 644 "${tmp}/geoip.dat" "${tmp}/geosite.dat" "$geo_dir/"
    rm -rf "$tmp"
    kokoro_log "geodata installed to ${geo_dir}"
}

kokoro_geodata_update() {
    kokoro_need_root
    kokoro_geodata_install
}
