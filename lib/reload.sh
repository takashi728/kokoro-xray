#!/usr/bin/env bash
# kokoro-xray — restart services based on role/mode

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

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
}
