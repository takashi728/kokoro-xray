#!/usr/bin/env bash
# kokoro-xray — Xray-core install and service

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/geodata.sh"

kokoro_xray_load_paths() {
    dest="$(kokoro_cfg '.paths.xray_bin')"
    geo_dir="$(kokoro_cfg '.paths.geo_dir')"
    xray_config="$(kokoro_cfg '.paths.xray_config')"

    kokoro_validate_service_paths
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
    local cfg unit
    kokoro_validate_service_paths
    cfg="$(kokoro_cfg '.paths.xray_config')"
    install -d "$(dirname "$cfg")"
    unit="$(kokoro_xray_unit_content)"
    kokoro_install_systemd_unit xray.service "$unit"
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
}

kokoro_xray_unit_content() {
    local bin cfg line
    bin="$(kokoro_cfg '.paths.xray_bin')"
    cfg="$(kokoro_cfg '.paths.xray_config')"
    kokoro_validate_service_paths
    line="ExecStart=${bin} run -config ${cfg}"
    cat <<EOF
[Unit]
Description=Xray Service (kokoro-xray)
After=network.target

[Service]
Type=simple
${line}
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}
