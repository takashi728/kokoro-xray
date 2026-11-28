#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export KOKORO_ROOT="$ROOT"
source "${ROOT}/lib/preflight.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
KOKORO_SSHD_CONFIG="${tmp_dir}/sshd_config"
trace="${tmp_dir}/ufw.log"
fail_at=""

kokoro_need_root() { :; }
kokoro_ensure_state() { :; }
kokoro_cfg() { jq -r "$1" "${tmp_dir}/config.json"; }
kokoro_preflight_paths() { :; }
kokoro_preflight_edge() { :; }
kokoro_preflight_exit() { :; }
kokoro_check_secret_perms() { :; }
ufw() {
    printf '%s\n' "$*" >>"$trace"
    [[ "$*" != "$fail_at" ]]
}

configure() {
    jq ".role = \"exit\" | $1" "${ROOT}/config.defaults.json" >"${tmp_dir}/config.json"
}

test_ssh_detect() {
    local port
    cat >"$KOKORO_SSHD_CONFIG" <<'EOF'
# comment
Port 2222
Port 3333
EOF
    port="$(kokoro_firewall_detect_ssh)"
    [[ "$port" == "3333" ]]
    echo "ssh_detect OK"
}

test_parse_allow() {
    [[ "$(kokoro_firewall_parse_allow '5555')" == "5555" ]]
    [[ "$(kokoro_firewall_parse_allow '5000-5010')" == "5000:5010" ]]
    [[ "$(kokoro_firewall_parse_allow '9000/udp')" == "9000/udp" ]]
    [[ "$(kokoro_firewall_parse_allow '5000:5010/tcp')" == "5000:5010/tcp" ]]
    [[ "$(kokoro_firewall_parse_allow $'\t8-09/udp  ')" == '8:09/udp' ]]
    if ( kokoro_firewall_parse_allow '99999' ) >/dev/null 2>&1; then
        echo "invalid port should fail"; exit 1
    fi
    if ( kokoro_firewall_parse_allow '100-50' ) >/dev/null 2>&1; then
        echo "invalid range should fail"; exit 1
    fi
    echo "parse_allow OK"
}

test_invalid_config() {
    local change entry
    for change in \
        '.firewall.ssh_port = 70000' \
        '.firewall.ssh_port = -1' \
        '.firewall.ssh_port = false' \
        '.multinode.exit_port = 0' \
        '.multinode.exit_port = "18446744073709551617"' \
        '.firewall.extra_allow = ["123", "44\u0027", "456"]' \
        '.firewall.extra_allow = ["\"443\""]' \
        '.firewall.extra_allow = ["22\n443"]' \
        '.firewall.extra_allow = [""]' \
        '.firewall.extra_allow = "443"' \
        '.role = "edge" | .inbound.hysteria = {enabled:true, ports:"443,bad,555"}'; do
        configure "$change"
        for entry in kokoro_preflight kokoro_firewall_apply; do
            : >"$trace"
            if ( "$entry" ) >"$tmp_dir/output" 2>&1; then
                echo "$entry accepted $change" >&2
                exit 1
            fi
            [[ ! -s "$trace" ]]
            grep -q 'invalid firewall configuration' "$tmp_dir/output"
        done
    done
    echo "invalid config rejected before UFW OK"
}

test_apply() {
    local change="$1" expected="$2" line_number=0
    configure "$change"
    : >"$trace"
    kokoro_preflight
    [[ ! -s "$trace" ]]
    kokoro_firewall_apply >"$tmp_dir/output"
    diff -u <(printf '%s\n' "$expected") "$trace"
    grep -q 'UFW active' "$tmp_dir/output"

    while IFS= read -r fail_at; do
        ((line_number += 1))
        : >"$trace"
        if ( kokoro_firewall_apply ) >"$tmp_dir/output" 2>&1; then
            echo "apply succeeded after failed ufw $fail_at" >&2
            exit 1
        fi
        diff -u <(head -n "$line_number" <<<"$expected") "$trace"
        if grep -q 'UFW active' "$tmp_dir/output"; then
            echo "reported success after failed ufw $fail_at" >&2
            exit 1
        fi
    done <<<"$expected"
    fail_at=""
}

test_ssh_detect
test_parse_allow
test_invalid_config
test_apply '.firewall.ssh_port = 1 | .multinode.exit_port = 65535 | .firewall.extra_allow = [5555, " 6000-6002/udp "]' \
'allow 1/tcp comment kokoro-ssh
allow 65535/udp comment kokoro-wg
allow 5555 comment kokoro-extra
allow 6000:6002/udp comment kokoro-extra
default deny incoming
default allow outgoing
--force enable
reload'
test_apply '.role = "edge" | .inbound.hysteria.enabled = true' \
'allow 3333/tcp comment kokoro-ssh
allow 443/tcp comment kokoro-xray
allow 80/tcp comment kokoro-acme
allow 443/udp comment kokoro-hysteria2
allow 20000:20020/udp comment kokoro-hysteria2
default deny incoming
default allow outgoing
--force enable
reload'
echo "firewall-test OK"
