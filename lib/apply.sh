#!/usr/bin/env bash
# kokoro-xray — render → validate → reload (with rollback)

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/snapshot.sh"
source "${KOKORO_ROOT}/lib/keys.sh"
source "${KOKORO_ROOT}/lib/preflight.sh"
source "${KOKORO_ROOT}/lib/render.sh"
source "${KOKORO_ROOT}/lib/validate.sh"
source "${KOKORO_ROOT}/lib/reload.sh"
source "${KOKORO_ROOT}/lib/firewall.sh"

kokoro_apply() {
    kokoro_need_root
    kokoro_ensure_state
    kokoro_ensure_vless_encryption_keys

    kokoro_preflight
    kokoro_snapshot_save

    if ! kokoro_render; then
        kokoro_snapshot_restore
        kokoro_die "render failed"
    fi

    if ! kokoro_validate; then
        if kokoro_snapshot_exists; then
            kokoro_warn "validation failed — rolling back"
            kokoro_snapshot_restore
            kokoro_reload
        fi
        kokoro_die "validation failed"
    fi

    kokoro_firewall_apply
    kokoro_reload
    kokoro_log "apply complete"
}
