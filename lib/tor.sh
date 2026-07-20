#!/usr/bin/env bash
# kokoro-xray — Tor SOCKS for .onion routing

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/os.sh"
source "${KOKORO_ROOT}/lib/apply.sh"

kokoro_tor_install() {
    kokoro_need_root
    kokoro_pkg_install tor
    systemctl enable tor >/dev/null 2>&1 || true
    kokoro_log "tor installed (socks 127.0.0.1:9050)"
}

kokoro_tor_require_exit() {
    local role edge_ip
    role="$(kokoro_cfg '.role')"
    [[ "$role" == "exit" ]] || kokoro_die "Tor runs on the exit node only (after multinode pair)"
    edge_ip="$(kokoro_cfg '.multinode.edge_ip')"
    [[ -n "$edge_ip" && "$edge_ip" != "null" ]] || kokoro_die "pair edge node first: kokoro-xray pair"
}

kokoro_tor_enable() {
    kokoro_ensure_state
    kokoro_tor_require_exit
    kokoro_tor_install
    kokoro_cfg_set '.tor.enabled' 'true'
    kokoro_apply
}

kokoro_tor_disable() {
    kokoro_ensure_state
    kokoro_tor_require_exit
    kokoro_cfg_set '.tor.enabled' 'false'
    kokoro_apply
}
