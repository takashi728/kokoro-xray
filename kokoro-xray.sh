#!/usr/bin/env bash
# kokoro-xray — main entrypoint

set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
export KOKORO_ROOT="$(cd -P -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
source "${KOKORO_ROOT}/lib/common.sh"

kokoro_ensure_state
kokoro_load_i18n

menu() {
    echo -e "${CYAN}${BOLD}kokoro-xray${NC} $(kokoro_t menu_subtitle)"
    echo ""
    echo "  1) $(kokoro_t menu_edge)"
    echo "  2) $(kokoro_t menu_exit)"
    echo "  3) $(kokoro_t menu_link)"
    echo "  4) $(kokoro_t menu_apply)"
    echo "  5) $(kokoro_t menu_pair)"
    echo "  6) $(kokoro_t menu_tor_on)"
    echo "  7) $(kokoro_t menu_tor_off)"
    echo "  8) $(kokoro_t menu_status)"
    echo "  9) $(kokoro_t menu_validate)"
    echo " 10) $(kokoro_t menu_reality_scan)"
    echo " 11) $(kokoro_t menu_tune)"
    echo "  q) $(kokoro_t menu_quit)"
    echo ""
}

kokoro_dispatch() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        edge)    bash "${KOKORO_ROOT}/roles/edge.sh" "$@" ;;
        exit)    bash "${KOKORO_ROOT}/roles/exit.sh" "$@" ;;
        link)    bash "${KOKORO_ROOT}/roles/client.sh" "$@" ;;
        firewall)
            shift || true
            source "${KOKORO_ROOT}/lib/firewall.sh"
            kokoro_firewall_cli "$@"
            ;;
        apply)   source "${KOKORO_ROOT}/lib/apply.sh"; kokoro_apply ;;
        pair)    bash "${KOKORO_ROOT}/roles/pair.sh" ;;
        status)  source "${KOKORO_ROOT}/lib/health.sh"; kokoro_health ;;
        validate) bash "${KOKORO_ROOT}/lib/validate.sh" ;;
        tor)
            case "${1:-}" in
                on)  source "${KOKORO_ROOT}/lib/tor.sh"; kokoro_tor_enable ;;
                off) source "${KOKORO_ROOT}/lib/tor.sh"; kokoro_tor_disable ;;
                *) kokoro_die "usage: kokoro-xray tor on|off" ;;
            esac ;;
        geodata)
            source "${KOKORO_ROOT}/lib/geodata.sh"
            kokoro_need_root
            kokoro_geodata_update
            ;;
        vless-encryption)
            source "${KOKORO_ROOT}/lib/vless-encryption.sh"
            case "${1:-}" in
                on) kokoro_vless_encryption_enable ;;
                off) kokoro_vless_encryption_disable ;;
                status) kokoro_vless_encryption_status ;;
                *) kokoro_die "usage: kokoro-xray vless-encryption on|off|status" ;;
            esac
            ;;
        reality)
            case "${1:-}" in
                scan) shift; bash "${KOKORO_ROOT}/roles/reality-scan.sh" "$@" ;;
                *) kokoro_die "usage: kokoro-xray reality scan [--apply|--select]" ;;
            esac ;;
        tune)
            shift || true
            source "${KOKORO_ROOT}/lib/network-tune.sh"
            kokoro_need_root
            kokoro_network_tune "$@"
            ;;
        reinstall)
            kokoro_need_root
            bash "${KOKORO_ROOT}/install.sh" --clean-install "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

if kokoro_dispatch "${1:-}" "${@:2}"; then
    exit 0
fi

if [[ ! -t 0 ]]; then
    menu
    exit 0
fi

while true; do
    menu
    read -r -p "$(kokoro_t menu_choice): " choice
    case "$choice" in
        1) bash "${KOKORO_ROOT}/roles/edge.sh" --keep-secrets --apply-edge ;;
        2) bash "${KOKORO_ROOT}/roles/exit.sh" --keep-secrets ;;
        3) bash "${KOKORO_ROOT}/roles/client.sh" --qr ;;
        4) source "${KOKORO_ROOT}/lib/apply.sh"; kokoro_apply ;;
        5) bash "${KOKORO_ROOT}/roles/pair.sh" ;;
        6)
            if [[ "$(kokoro_cfg '.role')" != "exit" ]]; then
                kokoro_warn "Tor is exit-only — install exit, pair, then enable Tor there"
            else
                source "${KOKORO_ROOT}/lib/tor.sh"; kokoro_tor_enable
            fi
            ;;
        7)
            if [[ "$(kokoro_cfg '.role')" != "exit" ]]; then
                kokoro_warn "Tor is exit-only"
            else
                source "${KOKORO_ROOT}/lib/tor.sh"; kokoro_tor_disable
            fi
            ;;
        8) source "${KOKORO_ROOT}/lib/health.sh"; kokoro_health ;;
        9) bash "${KOKORO_ROOT}/lib/validate.sh" ;;
        10) bash "${KOKORO_ROOT}/roles/reality-scan.sh" --limit 10 ;;
        11) source "${KOKORO_ROOT}/lib/network-tune.sh"; kokoro_need_root; kokoro_network_tune ;;
        q|Q) exit 0 ;;
        *) kokoro_warn "$(kokoro_t invalid_choice)" ;;
    esac
    echo ""
done
