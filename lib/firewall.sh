#!/usr/bin/env bash
# kokoro-xray — UFW firewall enablement

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

: "${KOKORO_SSHD_CONFIG:=/etc/ssh/sshd_config}"

kokoro_firewall_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 && "$p" -le 65535 ]]
}

kokoro_firewall_valid_ipv4() {
    local ip="$1" part
    local -a parts
    IFS='.' read -r -a parts <<<"$ip"
    [[ "${#parts[@]}" -eq 4 ]] || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        [[ "$part" -le 255 ]] || return 1
    done
}

kokoro_firewall_detect_ssh() {
    local port=22 line p
    if [[ -f "${KOKORO_SSHD_CONFIG}" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^[[:space:]]*Port[[:space:]]+([0-9]+) ]]; then
                p="${BASH_REMATCH[1]}"
                kokoro_firewall_valid_port "$p" && port="$p"
            fi
        done <"${KOKORO_SSHD_CONFIG}"
    fi
    echo "$port"
}

kokoro_firewall_ssh_port() {
    local cfg_port detected
    cfg_port="$(kokoro_cfg '.firewall.ssh_port // 0')"
    if [[ "$cfg_port" =~ ^[0-9]+$ ]] && [[ "$cfg_port" -gt 0 ]]; then
        echo "$cfg_port"
        return
    fi
    kokoro_firewall_detect_ssh
}

# Parse extra_allow spec → one or more ufw allow targets (one per line)
# 5555 → 5555 (tcp+udp)
# 5000-5010 → 5000:5010
# 9000/tcp → 9000/tcp
# 5000-5010/udp → 5000:5010/udp
kokoro_firewall_parse_allow() {
    local spec="$1" body proto start end a b

    spec="$(echo "$spec" | xargs)"
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
        [[ "$start" -le "$end" ]] || kokoro_die "invalid port range (start>end): $spec"
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
    local -a items=()
    local item
    mapfile -t items < <(jq -r '.firewall.extra_allow[]? // empty' "${KOKORO_CONFIG}" 2>/dev/null)
    for item in "${items[@]}"; do
        [[ -n "$item" ]] && kokoro_firewall_parse_allow "$item" >/dev/null
    done
}

kokoro_firewall_ufw_allow() {
    local spec="$1" comment="$2"
    ufw allow "$spec" comment "$comment" >/dev/null 2>&1 || true
}

kokoro_firewall_ufw_allow_from() {
    local source="$1" port="$2" proto="$3" comment="$4"
    ufw allow from "$source" to any port "$port" proto "$proto" comment "$comment" >/dev/null 2>&1 \
        || kokoro_die "failed to restrict ${port}/${proto} to ${source}"
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
            ;;
        exit)
            kokoro_warn "firewall disabled - allow ${port}/tcp from the edge IPv4 only"
            ;;
    esac
}

kokoro_firewall_service_rules() {
    local role mode exit_port edge_ip
    role="$(kokoro_cfg '.role')"
    mode="$(kokoro_cfg '.inbound.mode')"
    exit_port="$(kokoro_cfg '.multinode.exit_port')"

    case "$role" in
        edge)
            if [[ "$mode" == "tls" || "$mode" == "both" || "$mode" == "reality" ]]; then
                kokoro_firewall_ufw_allow "443/tcp" "kokoro-xray"
                kokoro_firewall_ufw_allow "80/tcp" "kokoro-acme"
            fi
            ;;
        exit)
            edge_ip="$(kokoro_cfg '.multinode.edge_ip')"
            kokoro_firewall_ufw_allow_from "$edge_ip" "$exit_port" tcp "kokoro-vless-pqc"
            ;;
    esac
}

kokoro_firewall_extra_rules() {
    local -a items=() specs=()
    local item spec
    mapfile -t items < <(jq -r '.firewall.extra_allow[]? // empty' "${KOKORO_CONFIG}" 2>/dev/null)
    for item in "${items[@]}"; do
        [[ -z "$item" ]] && continue
        mapfile -t specs < <(kokoro_firewall_parse_allow "$item")
        for spec in "${specs[@]}"; do
            kokoro_firewall_ufw_allow "$spec" "kokoro-extra"
        done
    done
}

kokoro_firewall_apply_enabled() {
    local ssh_port
    command -v ufw >/dev/null 2>&1 || kokoro_die "ufw not installed (apt install ufw)"

    ssh_port="$(kokoro_firewall_ssh_port)"
    kokoro_log "firewall: SSH tcp/${ssh_port}, enabling UFW..."

    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true

    kokoro_firewall_ufw_allow "${ssh_port}/tcp" "kokoro-ssh"
    kokoro_firewall_service_rules
    kokoro_firewall_extra_rules

    ufw --force enable >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    kokoro_log "firewall: UFW active (ssh=${ssh_port})"
}

kokoro_firewall_apply() {
    kokoro_need_root
    kokoro_ensure_state

    if [[ "$(kokoro_cfg '.firewall.enabled // false')" != "true" ]]; then
        kokoro_firewall_warn_only
        return 0
    fi

    kokoro_firewall_validate_extra
    kokoro_firewall_apply_enabled
}

kokoro_firewall_status() {
    local ssh_port
    kokoro_ensure_state
    ssh_port="$(kokoro_firewall_ssh_port)"

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
