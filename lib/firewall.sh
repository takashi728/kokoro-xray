#!/usr/bin/env bash
# kokoro-xray — UFW firewall enablement

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

: "${KOKORO_SSHD_CONFIG:=/etc/ssh/sshd_config}"

kokoro_firewall_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 ))
}

kokoro_firewall_detect_ssh() {
    local port=22 line p
    if [[ -f "${KOKORO_SSHD_CONFIG}" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^[[:space:]]*Port[[:space:]]+([0-9]+) ]]; then
                p="${BASH_REMATCH[1]}"
                if kokoro_firewall_valid_port "$p"; then port="$p"; fi
            fi
        done <"${KOKORO_SSHD_CONFIG}" || return 1
    fi
    echo "$port"
}

kokoro_firewall_ssh_port() {
    local cfg_port
    cfg_port="$(kokoro_cfg '.firewall.ssh_port | if . == null then 0 else . end')" || return 1
    if [[ "$cfg_port" == 0 ]]; then
        kokoro_firewall_detect_ssh
    else
        kokoro_firewall_valid_port "$cfg_port" || kokoro_die "invalid firewall.ssh_port: $cfg_port"
        printf '%s\n' "$cfg_port"
    fi
}

# Parse extra_allow spec → one or more ufw allow targets (one per line)
# 5555 → 5555 (tcp+udp)
# 5000-5010 → 5000:5010
# 9000/tcp → 9000/tcp
# 5000-5010/udp → 5000:5010/udp
kokoro_firewall_parse_allow() {
    local spec="$1" body proto start end

    spec="${spec#"${spec%%[![:space:]]*}"}"
    spec="${spec%"${spec##*[![:space:]]}"}"
    [[ -n "$spec" ]] || { kokoro_die "empty firewall allow spec"; return 1; }

    proto=""
    body="$spec"
    if [[ "$spec" == */tcp ]]; then
        proto="tcp"
        body="${spec%/tcp}"
    elif [[ "$spec" == */udp ]]; then
        proto="udp"
        body="${spec%/udp}"
    fi

    if [[ "$body" == *-* || "$body" == *:* ]]; then
        if [[ "$body" == *-* ]]; then
            start="${body%%-*}"
            end="${body#*-}"
        else
            start="${body%%:*}"
            end="${body#*:}"
        fi
        kokoro_firewall_valid_port "$start" || kokoro_die "invalid port range: $spec"
        kokoro_firewall_valid_port "$end" || kokoro_die "invalid port range: $spec"
        (( 10#$start <= 10#$end )) || kokoro_die "invalid port range (start>end): $spec"
        if [[ -n "$proto" ]]; then
            printf '%s:%s/%s\n' "$start" "$end" "$proto"
        else
            printf '%s:%s\n' "$start" "$end"
        fi
        return 0
    fi

    kokoro_firewall_valid_port "$body" || kokoro_die "invalid port: $spec"
    if [[ -n "$proto" ]]; then
        printf '%s/%s\n' "$body" "$proto"
    else
        printf '%s\n' "$body"
    fi
}

kokoro_firewall_validate_extra() {
    local validated_rules
    validated_rules="$(kokoro_firewall_rules)" || kokoro_die "invalid firewall configuration"
    if (( $# )); then
        local -n output_rules="$1"
        output_rules="$validated_rules"
    fi
}

kokoro_firewall_warn_only() {
    local role mode port
    role="$(kokoro_cfg '.role')"
    mode="$(kokoro_cfg '.inbound.mode')"
    port="$(kokoro_cfg '.multinode.exit_port')"

    case "$role" in
        edge)
            if [[ "$mode" == "tls" || "$mode" == "both" || "$mode" == "reality" ]]; then
                kokoro_warn "firewall disabled — ensure: 443/tcp, 80/tcp"
            fi
            if [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]]; then
                kokoro_warn "firewall disabled — also allow UDP: $(kokoro_cfg '.inbound.hysteria.ports')"
            fi
            ;;
        exit)
            kokoro_warn "firewall disabled — ensure: ${port}/udp"
            ;;
    esac
}

kokoro_firewall_ufw_allow() {
    ufw allow "$1" comment "$2" >/dev/null || kokoro_die "ufw allow failed: $1 ($2)"
}

kokoro_firewall_print_rule() {
    printf '%s %s\n' "$1" "$2"
}

kokoro_firewall_service_rules() {
    local emit="${1:-kokoro_firewall_ufw_allow}" role mode wg_port hysteria ports item spec
    role="$(kokoro_cfg '.role')" || return 1
    if [[ "$role" == exit || "$(kokoro_cfg '.multinode.enabled // false')" == true ]]; then
        wg_port="$(kokoro_cfg '.multinode.exit_port')" || return 1
        kokoro_firewall_valid_port "$wg_port" || kokoro_die "invalid multinode.exit_port: $wg_port"
    fi

    case "$role" in
        edge)
            mode="$(kokoro_cfg '.inbound.mode')" || return 1
            if [[ "$mode" == "tls" || "$mode" == "both" || "$mode" == "reality" ]]; then
                "$emit" '443/tcp' 'kokoro-xray' || return 1
                "$emit" '80/tcp' 'kokoro-acme' || return 1
            fi
            hysteria="$(kokoro_cfg '.inbound.hysteria.enabled // false')" || return 1
            if [[ "$hysteria" == true ]]; then
                ports="$(kokoro_cfg '.inbound.hysteria.ports')" || return 1
                while IFS= read -r item; do
                    spec="$(kokoro_firewall_parse_allow "${item}/udp")" || return 1
                    "$emit" "$spec" 'kokoro-hysteria2' || return 1
                done <<<"${ports//,/$'\n'}"
            fi
            ;;
        exit)
            "$emit" "${wg_port}/udp" 'kokoro-wg' || return 1
            ;;
    esac
}

kokoro_firewall_rules() {
    local ssh_port item spec extras
    ssh_port="$(kokoro_firewall_ssh_port)" || return 1
    kokoro_firewall_print_rule "${ssh_port}/tcp" kokoro-ssh || return 1
    kokoro_firewall_service_rules kokoro_firewall_print_rule || return 1
    extras="$(kokoro_cfg '
        .firewall.extra_allow | if . == null then [] else . end
        | if type == "array" then .[] else error("expected firewall.extra_allow array") end
        | if type == "number" then tostring
          elif type == "string" and length > 0 and index("\u0000") == null then gsub("\n"; " ")
          else error("invalid firewall.extra_allow entry") end
    ')" || return 1
    if [[ -n "$extras" ]]; then
        while IFS= read -r item; do
            spec="$(kokoro_firewall_parse_allow "$item")" || return 1
            kokoro_firewall_print_rule "$spec" kokoro-extra || return 1
        done <<<"$extras"
    fi
}

kokoro_firewall_apply_enabled() {
    local rules="" spec comment
    command -v ufw >/dev/null 2>&1 || kokoro_die "ufw not installed (apt install ufw)"
    kokoro_firewall_validate_extra rules || return 1
    while read -r spec comment; do
        kokoro_firewall_ufw_allow "$spec" "$comment" || return 1
    done <<<"$rules"
    ufw default deny incoming >/dev/null || kokoro_die "ufw default deny incoming failed"
    ufw default allow outgoing >/dev/null || kokoro_die "ufw default allow outgoing failed"
    ufw --force enable >/dev/null || kokoro_die "ufw enable failed"
    ufw reload >/dev/null || kokoro_die "ufw reload failed"
    kokoro_log "firewall: UFW active (ssh=${rules%%/*})"
}

kokoro_firewall_apply() {
    local enabled
    kokoro_need_root || return 1
    kokoro_ensure_state || return 1

    enabled="$(kokoro_cfg '.firewall.enabled // false')" || return 1
    if [[ "$enabled" != "true" ]]; then
        kokoro_firewall_warn_only
        return 0
    fi

    kokoro_firewall_apply_enabled
}

kokoro_firewall_status() {
    local ssh_port
    kokoro_ensure_state
    ssh_port="$(kokoro_firewall_ssh_port)" || return 1

    echo "firewall.enabled: $(kokoro_cfg '.firewall.enabled // false')"
    echo "ssh_port:         ${ssh_port} (config=$(kokoro_cfg '.firewall.ssh_port // 0'), 0=auto)"
    echo "extra_allow:      $(jq -c '.firewall.extra_allow // []' "${KOKORO_CONFIG}")"
    echo ""
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose 2>/dev/null || ufw status 2>/dev/null || echo "ufw: unavailable"
    else
        echo "ufw: not installed"
    fi
}

kokoro_firewall_cli() {
    case "${1:-}" in
        status) kokoro_firewall_status ;;
        apply)  kokoro_firewall_apply ;;
        -h|--help)
            cat <<'EOF'
kokoro-xray firewall — UFW management

Usage:
  kokoro-xray firewall status
  kokoro-xray firewall apply
EOF
            ;;
        *) kokoro_die "usage: kokoro-xray firewall status|apply" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kokoro_firewall_cli "$@"
fi
