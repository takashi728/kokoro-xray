#!/usr/bin/env bash
# kokoro-xray — restart services based on role/mode

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_hysteria_cert_path_unit() { # cert key
    local cert="$1" key="$2"
    printf '%s\n' \
        '[Path]' \
        "PathChanged=${cert}" \
        "PathChanged=${key}" \
        'Unit=kokoro-hysteria-cert-reload.service'
}

kokoro_hysteria_cert_service_unit() {
    printf '%s\n' \
        '[Unit]' \
        'Description=Restart Xray after Hysteria2 certificate renewal' \
        'After=xray.service' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        'ExecStartPre=/usr/bin/sleep 2' \
        'ExecStart=/usr/bin/systemctl restart xray.service'
}

kokoro_hysteria_cert_reload_sync() {
    local cert key enabled unit_dir path_unit service_unit changed=false
    enabled="$(kokoro_cfg '.inbound.hysteria.enabled // false')"
    unit_dir="$(kokoro_systemd_unit_dir)"
    path_unit="${unit_dir}/kokoro-hysteria-cert.path"
    service_unit="${unit_dir}/kokoro-hysteria-cert-reload.service"

    if [[ "$enabled" != "true" ]]; then
        if [[ -e "$path_unit" || -e "$service_unit" ]]; then
            rm -f "$path_unit" "$service_unit"
            changed=true
        fi
    else
        cert="$(kokoro_cfg '.paths.hysteria_cert')"
        key="$(kokoro_cfg '.paths.hysteria_key')"
        kokoro_require_hysteria_file '.paths.hysteria_cert' '.crt'
        kokoro_require_hysteria_file '.paths.hysteria_key' '.key'
        local path_content service_content
        path_content="$(kokoro_hysteria_cert_path_unit "$cert" "$key")"
        service_content="$(kokoro_hysteria_cert_service_unit)"
        if [[ "$path_content" != "$(cat "$path_unit" 2>/dev/null || true)" ]]; then
            kokoro_install_systemd_unit kokoro-hysteria-cert.path "$path_content"
            changed=true
        fi
        if [[ "$service_content" != "$(cat "$service_unit" 2>/dev/null || true)" ]]; then
            kokoro_install_systemd_unit kokoro-hysteria-cert-reload.service "$service_content"
            changed=true
        fi
    fi

    if [[ "$changed" == "true" ]]; then
        systemctl daemon-reload
    fi
    if [[ "$enabled" == "true" ]]; then
        systemctl enable --now kokoro-hysteria-cert.path >/dev/null 2>&1 ||
            kokoro_warn "failed to start Hysteria2 certificate renewal watcher"
    else
        systemctl disable kokoro-hysteria-cert.path >/dev/null 2>&1 || true
    fi
}

kokoro_reload() {
    kokoro_need_root
    local role
    role="$(kokoro_cfg '.role')"

    if [[ "$role" == "edge" ]] && ! kokoro_caddy_required; then
        systemctl disable --now caddy >/dev/null 2>&1 || true
    fi

    systemctl restart xray

    if [[ "$role" == "edge" ]] && kokoro_caddy_required; then
        systemctl enable caddy >/dev/null 2>&1 || true
        systemctl restart caddy
    fi

    if [[ "$role" == "exit" && "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
        systemctl enable tor >/dev/null 2>&1 || true
        systemctl restart tor
    fi

    kokoro_hysteria_cert_reload_sync
}
