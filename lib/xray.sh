#!/usr/bin/env bash
# kokoro-xray — Xray-core install and service

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/geodata.sh"

kokoro_xray_load_paths() {
    dest="$(kokoro_cfg '.paths.xray_bin')"
    geo_dir="$(kokoro_cfg '.paths.geo_dir')"
    xray_config="$(kokoro_cfg '.paths.xray_config')"

    [[ -n "$dest" && "$dest" != "null" ]] || kokoro_die "missing required config path: .paths.xray_bin"
    [[ -n "$geo_dir" && "$geo_dir" != "null" ]] || kokoro_die "missing required config path: .paths.geo_dir"
    [[ -n "$xray_config" && "$xray_config" != "null" ]] || kokoro_die "missing required config path: .paths.xray_config"
}

kokoro_xray_install() {
    local zip dest geo_dir xray_config tmp staged
    kokoro_need_root
    kokoro_xray_load_paths
    tmp="$(mktemp -d)"
    zip="$(kokoro_xray_download_release_zip "$tmp")"
    unzip -qo "${tmp}/${zip}" -d "$tmp"
    staged="${dest}.new.$$"
    install -m 755 "${tmp}/xray" "$staged"
    "$staged" version >/dev/null 2>&1 ||
        { rm -f "$staged"; rm -rf "$tmp"; kokoro_die "downloaded Xray binary is not executable"; }
    if [[ -e "$dest" ]]; then
        mv "$dest" "${dest}.old.$$"
    fi
    if ! mv "$staged" "$dest"; then
        [[ -e "${dest}.old.$$" ]] && mv "${dest}.old.$$" "$dest"
        rm -f "$staged"
        rm -rf "$tmp"
        kokoro_die "failed to activate downloaded Xray binary"
    fi
    rm -f "${dest}.old.$$"
    install -d "$geo_dir"
    install -m 644 "${tmp}/geoip.dat" "${tmp}/geosite.dat" "$geo_dir/"
    rm -rf "$tmp"
    kokoro_xray_install_service
    kokoro_log "xray ${KOKORO_XRAY_VERSION} installed"
}

kokoro_xray_install_service() {
    local cfg
    cfg="$(kokoro_cfg '.paths.xray_config')"
    install -d "$(dirname "$cfg")"
    cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (kokoro-xray)
After=network.target

[Service]
Type=simple
ExecStart=$(kokoro_cfg '.paths.xray_bin') run -config ${cfg}
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
}
