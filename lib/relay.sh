#!/usr/bin/env bash
# kokoro-xray - high-assurance edge/exit pairing bundle

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/firewall.sh"

kokoro_relay_public_ipv4() {
    curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
        || hostname -I | awk '{
             for (i = 1; i <= NF; i++)
               if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                 print $i
                 exit
               }
           }'
}

kokoro_relay_export_bundle() {
    local exit_ip="${1:-}"
    [[ -n "$exit_ip" ]] || exit_ip="$(kokoro_relay_public_ipv4)"
    [[ -n "$exit_ip" ]] || kokoro_die "cannot detect exit public IPv4"
    kokoro_firewall_valid_ipv4 "$exit_ip" || kokoro_die "invalid exit public IPv4"
    jq -cn \
        --arg transport "vless-pqc" \
        --arg exit_ip "$exit_ip" \
        --argjson exit_port "$(kokoro_cfg '.multinode.exit_port')" \
        --arg uuid "$(kokoro_sec '.multinode.exit_vless_uuid')" \
        --arg encryption "$(kokoro_sec '.multinode.exit_vless_encryption')" \
        '{
          transport: $transport,
          exit_ip: $exit_ip,
          exit_port: $exit_port,
          uuid: $uuid,
          encryption: $encryption
        }'
}

kokoro_relay_import_bundle() {
    local bundle="$1" exit_ip exit_port uuid encryption
    printf '%s' "$bundle" | jq -e '
      .transport == "vless-pqc"
      and (.exit_ip | type == "string" and length > 0)
      and (.exit_port | type == "number" and . >= 1 and . <= 65535)
      and (.uuid | type == "string"
           and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
      and (.encryption | type == "string"
           and test("^mlkem768x25519plus\\.native\\.0rtt\\.[A-Za-z0-9_-]{1579}$"))
    ' >/dev/null || kokoro_die "invalid exit relay bundle"

    exit_ip="$(printf '%s' "$bundle" | jq -r '.exit_ip')"
    exit_port="$(printf '%s' "$bundle" | jq -r '.exit_port')"
    uuid="$(printf '%s' "$bundle" | jq -r '.uuid')"
    encryption="$(printf '%s' "$bundle" | jq -r '.encryption')"
    kokoro_firewall_valid_ipv4 "$exit_ip" || kokoro_die "invalid exit public IPv4"

    kokoro_cfg_set_str '.multinode.transport' 'vless-pqc'
    kokoro_cfg_set_str '.multinode.exit_ip' "$exit_ip"
    kokoro_cfg_set '.multinode.exit_port' "$exit_port"
    kokoro_cfg_set '.multinode.enabled' 'true'
    kokoro_sec_set_str '.multinode.exit_vless_uuid' "$uuid"
    kokoro_sec_set_str '.multinode.exit_vless_encryption' "$encryption"
}
