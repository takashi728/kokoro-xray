#!/usr/bin/env bash
# kokoro-xray — restart services based on role/mode

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/fallback.sh"

kokoro_cert_path_unit() { # cert key service prefix
    local cert="$1" key="$2" prefix="$3"
    printf '%s\n' \
        '[Path]' \
        "PathChanged=${cert}" \
        "PathChanged=${key}" \
        "Unit=kokoro-${prefix}-cert-reload.service" \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target'
}

kokoro_cert_service_unit() {
    printf '%s\n' \
        '[Unit]' \
        'Description=Restart Xray after managed TLS certificate renewal' \
        'After=xray.service' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        'ExecStartPre=/usr/bin/sleep 2' \
        'ExecStart=/usr/bin/systemctl restart xray.service'
}

kokoro_cert_reload_sync() {
    local prefix="$1" cert key enabled=false unit_dir path_unit service_unit changed=false
    case "$prefix" in
        hysteria) enabled="$(kokoro_cfg '.inbound.hysteria.enabled // false')" ;;
        tls) if kokoro_raw_tls_enabled; then enabled=true; fi ;;
        *) kokoro_die "invalid certificate watcher prefix" ;;
    esac
    unit_dir="$(kokoro_systemd_unit_dir)"
    path_unit="${unit_dir}/kokoro-${prefix}-cert.path"
    service_unit="${unit_dir}/kokoro-${prefix}-cert-reload.service"

    if [[ "$enabled" != "true" ]]; then
        if [[ -e "$path_unit" || -e "$service_unit" ]]; then
            systemctl disable --now "kokoro-${prefix}-cert.path" >/dev/null 2>&1 || true
            rm -f "$path_unit" "$service_unit"
            changed=true
        fi
    else
        cert="$(kokoro_cfg ".paths.${prefix}_cert")"
        key="$(kokoro_cfg ".paths.${prefix}_key")"
        kokoro_require_hysteria_file ".paths.${prefix}_cert" '.crt'
        kokoro_require_hysteria_file ".paths.${prefix}_key" '.key'
        local path_content service_content
        path_content="$(kokoro_cert_path_unit "$cert" "$key" "$prefix")"
        service_content="$(kokoro_cert_service_unit)"
        if [[ "$path_content" != "$(cat "$path_unit" 2>/dev/null || true)" ]]; then
            kokoro_install_systemd_unit "kokoro-${prefix}-cert.path" "$path_content"
            changed=true
        fi
        if [[ "$service_content" != "$(cat "$service_unit" 2>/dev/null || true)" ]]; then
            kokoro_install_systemd_unit "kokoro-${prefix}-cert-reload.service" "$service_content"
            changed=true
        fi
    fi

    if [[ "$changed" == "true" ]]; then
        systemctl daemon-reload
    fi
    if [[ "$enabled" == "true" ]]; then
        systemctl enable --now "kokoro-${prefix}-cert.path" >/dev/null 2>&1 ||
            kokoro_warn "failed to start ${prefix} certificate renewal watcher"
    fi
}

kokoro_hysteria_cert_reload_sync() { kokoro_cert_reload_sync hysteria; }

kokoro_reload() {
    kokoro_need_root
    local role
    role="$(kokoro_cfg '.role')"

    if [[ "$role" == "edge" ]] && ! kokoro_caddy_required; then
        systemctl disable --now caddy >/dev/null 2>&1 || true
    fi

    kokoro_fallback_sync || kokoro_die "fallback service synchronization failed"
    systemctl restart xray || kokoro_die "Xray restart failed"

    if [[ "$role" == "edge" ]] && kokoro_caddy_required; then
        systemctl enable caddy >/dev/null 2>&1 || true
        systemctl restart caddy || kokoro_die "Caddy restart failed"
    fi

    if [[ "$role" == "exit" && "$(kokoro_cfg '.tor.enabled')" == "true" ]]; then
        systemctl enable tor >/dev/null 2>&1 || true
        systemctl restart tor
    fi

    kokoro_hysteria_cert_reload_sync
    kokoro_cert_reload_sync tls
}
