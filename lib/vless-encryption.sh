#!/usr/bin/env bash
# kokoro-xray — VLESS Encryption toggle

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/keys.sh"
source "${KOKORO_ROOT}/lib/apply.sh"

kokoro_vless_encryption_require_edge() {
    [[ "$(kokoro_cfg '.role')" == "edge" ]] || kokoro_die "VLESS Encryption is edge-only"
}

kokoro_vless_encryption_enable() {
    kokoro_need_root
    kokoro_ensure_state
    kokoro_vless_encryption_require_edge
    kokoro_cfg_set '.inbound.vless_encryption.enabled' 'true'
    kokoro_ensure_vless_encryption_keys
    kokoro_apply
    kokoro_warn "VLESS Encryption enabled; refresh client links"
}

kokoro_vless_encryption_disable() {
    kokoro_need_root
    kokoro_ensure_state
    kokoro_vless_encryption_require_edge
    kokoro_cfg_set '.inbound.vless_encryption.enabled' 'false'
    kokoro_apply
    kokoro_warn "VLESS Encryption disabled; refresh client links"
}

kokoro_vless_encryption_status() {
    kokoro_ensure_state
    kokoro_vless_encryption_require_edge
    printf '%s\n' "$(kokoro_cfg '.inbound.vless_encryption.enabled // false')"
}
