#!/usr/bin/env bash

kokoro_argo_validate() {
    local host preferred
    host="$(kokoro_cfg '.argo.hostname')"; preferred="$(kokoro_cfg '.argo.preferred_ip')"
    if ! jq -e --slurpfile secrets "$KOKORO_SECRETS" '
      . as $cfg | .argo as $a | $secrets[0] as $s |
      .role=="edge" and .inbound.vless_encryption.enabled==true and
      ([$s.inbound.uuid,$s.inbound.vless_encryption.encryption,$s.inbound.vless_encryption.decryption] |
        all(type=="string" and length>0 and .!="none")) and
      ($a.mode|IN("named","quick")) and ($a.protocol|IN("quic","http2")) and
      ($a.local_port|type=="number" and floor==. and .>=1 and .<=65535 and
        (IN(80,443,8080,8081,8443,8444,$cfg.firewall.ssh_port)|not)) and
      ($a.xhttp_path|type=="string" and test("\\A/[A-Za-z0-9_-]{1,128}\\z")) and
      ($a.xhttp_mode|IN("auto","packet-up")) and
      ($a.mode=="quick" or ($s.argo.tunnel_token|type=="string" and test("\\A[A-Za-z0-9_+/=-]+\\z")))
      ' "$KOKORO_CONFIG" >/dev/null ||
       { [[ -n $preferred ]] && ! kokoro_cf_host "$preferred"; }; then
        kokoro_warn "$(kokoro_cf_text argo_invalid)"; return 1
    fi
    if [[ $(kokoro_cfg '.argo.mode') == named ]] && ! kokoro_cf_domain "$host"; then
        kokoro_warn "$(kokoro_cf_text argo_invalid)"; return 1
    fi
    source "${KOKORO_ROOT}/lib/firewall.sh"
    kokoro_firewall_rules >/dev/null || return 1
}

kokoro_argo_install() (
    set -euo pipefail
    local arch digest binary=/usr/local/bin/cloudflared mode
    case "$(uname -m)" in
        x86_64) arch=amd64; digest=56f13335143ec0e22772963290683a84a04114a35ec64cbc794a4d39ff9bb8cf ;;
        aarch64|arm64) arch=arm64; digest=04a7b7f08bce85d56b26ffe1fdbfbb21a074495a363d16f0783c40e25b5c5281 ;;
        *) kokoro_die "$(kokoro_cf_text argo_binary)" ;;
    esac
    if [[ -e $binary || -L $binary ]]; then
        mode="$(stat -c %a -- "$binary")" || return 1
        if [[ ! -f $binary || -L $binary || ! -x $binary || $(stat -c %u -- "$binary") != 0 ]] ||
           (( (8#$mode & 8#022) != 0 )) || ! printf '%s  %s\n' "$digest" "$binary" | sha256sum --check --status; then
            kokoro_die "$(kokoro_cf_text argo_binary)"
        fi
        return
    fi
    argo_stage="$(mktemp /usr/local/bin/.kokoro-cloudflared.XXXXXXXX)" || return 1
    trap 'rm -f -- "$argo_stage"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        "https://github.com/cloudflare/cloudflared/releases/download/2026.11.2/cloudflared-linux-$arch" -o "$argo_stage" || return 1
    printf '%s  %s\n' "$digest" "$argo_stage" | sha256sum --check --status || kokoro_die "$(kokoro_cf_text argo_binary)"
    chmod 755 "$argo_stage" || return 1
    mv -T "$argo_stage" "$binary"
)

kokoro_argo_unit() {
    local protocol port args environment=""
    protocol="$(kokoro_cfg '.argo.protocol')"; port="$(kokoro_cfg '.argo.local_port')"
    [[ $protocol =~ ^(quic|http2)$ && $port =~ ^[0-9]{1,5}$ ]] || return 1
    case "$(kokoro_cfg '.argo.mode')" in
        named) environment='EnvironmentFile=/etc/kokoro-xray/cloudflared.env'; args=run ;;
        quick) args="--url http://127.0.0.1:$port" ;;
        *) return 1 ;;
    esac
    cat <<EOF
[Unit]
Description=Cloudflare Tunnel for kokoro-xray
After=network-online.target xray.service
Wants=network-online.target

[Service]
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
$environment
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol $protocol $args
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

kokoro_argo_env() {
    jq -er '.argo.tunnel_token | select(test("\\A[A-Za-z0-9_+/=-]+\\z")) | "TUNNEL_TOKEN="+.' "$KOKORO_SECRETS"
}

kokoro_argo_sync() {
    local name=kokoro-cloudflared.service unit envfile=/etc/kokoro-xray/cloudflared.env content changed=false
    unit="$(kokoro_systemd_unit_dir)/$name"
    if [[ $(kokoro_cfg '.argo.enabled // false') != true ]]; then
        if [[ -e $unit ]]; then
            systemctl disable --now "$name" || return 1
            rm -f -- "$unit" || return 1
            systemctl daemon-reload || return 1
        fi
        rm -f -- "$envfile"
        return
    fi
    kokoro_argo_validate || return 1
    kokoro_argo_install || return 1
    content="$(kokoro_argo_unit)" || return 1
    if [[ ! -f $unit || $content != "$(cat -- "$unit")" ]]; then
        kokoro_install_systemd_unit "$name" "$content" || return 1
        systemctl daemon-reload || return 1
        changed=true
    fi
    if [[ $(kokoro_cfg '.argo.mode') == named ]]; then
        if [[ ! -d /etc/kokoro-xray ]]; then install -d -m 700 /etc/kokoro-xray || return 1; fi
        if [[ ! -f $envfile ]] || ! kokoro_argo_env | cmp -s - "$envfile"; then
            kokoro_write_private "$envfile" kokoro_argo_env || return 1
            changed=true
        fi
        chmod 600 "$envfile" || return 1
    else
        rm -f -- "$envfile" || return 1
    fi
    systemctl enable "$name" || return 1
    if [[ $changed == true ]]; then systemctl restart "$name"; else systemctl start "$name"; fi
}

kokoro_argo_hostname() {
    local invocation
    if [[ $(kokoro_cfg '.argo.mode') == named ]]; then kokoro_cfg '.argo.hostname'; return; fi
    invocation="$(systemctl show --property=InvocationID --value kokoro-cloudflared.service 2>/dev/null)" || return 1
    [[ $invocation =~ ^[a-fA-F0-9]{32}$ ]] || return 1
    journalctl -q --no-pager -o cat -u kokoro-cloudflared.service "_SYSTEMD_INVOCATION_ID=$invocation" |
        sed -nE 's@.*https://([a-z0-9-]+\.trycloudflare\.com)([[:space:]|/].*|$)@\1@p' | tail -1
}

kokoro_argo_status() {
    local hostname="" service
    if [[ $(kokoro_cfg '.argo.enabled') == true ]]; then hostname="$(kokoro_argo_hostname)" || hostname=""; fi
    service="$(systemctl is-active kokoro-cloudflared.service 2>/dev/null)" || service="${service:-unknown}"
    printf 'Argo Tunnel %s %s %s\n' "$service" "${hostname:--}" \
        "$(jq -cr '.argo | {enabled,mode,protocol,local_port}' "$KOKORO_CONFIG")"
}

kokoro_argo_setup() {
    local mode protocol port host preferred path token_file="" tunnel_only=false token
    mode="$(kokoro_cfg '.argo.mode')"; protocol="$(kokoro_cfg '.argo.protocol')"; port="$(kokoro_cfg '.argo.local_port')"
    host="$(kokoro_cfg '.argo.hostname')"; preferred="$(kokoro_cfg '.argo.preferred_ip')"; path="$(kokoro_cfg '.argo.xhttp_path')"
    if [[ $# == 0 && -t 0 ]]; then
        mode="$(kokoro_cf_prompt argo_mode "$mode")"
        if [[ $mode == named ]]; then host="$(kokoro_cf_prompt argo_host "$host")"; fi
        protocol="$(kokoro_cf_prompt argo_protocol "$protocol")"; port="$(kokoro_cf_prompt argo_port "$port")"
        preferred="$(kokoro_cf_prompt argo_preferred "$preferred")"
    fi
    while (( $# )); do
        if [[ $1 == --tunnel-only ]]; then tunnel_only=true; shift; continue; fi
        [[ $# -ge 2 ]] || kokoro_die "$(kokoro_cf_text cf_usage)"
        case "$1" in
            --mode) mode="$2" ;; --protocol) protocol="$2" ;; --local-port) port="$2" ;;
            --hostname) host="$2" ;; --preferred-ip) preferred="$2" ;; --token-file) token_file="$2" ;;
            *) kokoro_die "$(kokoro_cf_text cf_usage)" ;;
        esac
        shift 2
    done
    if [[ $mode == named ]]; then
        if [[ -n $token_file ]]; then kokoro_cf_secret '.argo.tunnel_token' <"$token_file"
        elif [[ -t 0 && -z $(kokoro_sec '.argo.tunnel_token') ]]; then
            read -rs -p "$(kokoro_cf_text argo_token): " token
            printf '\n' >&2
            kokoro_cf_secret '.argo.tunnel_token' <<<"$token"
        fi
    elif [[ $mode == quick ]]; then host=""; kokoro_cf_secret '.argo.tunnel_token' </dev/null; fi
    if [[ -z $path ]]; then source "$KOKORO_ROOT/lib/keys.sh"; path="$(kokoro_rand_path)"; fi
    # shellcheck disable=SC2016
    kokoro_write_private "$KOKORO_CONFIG" jq --arg mode "$mode" --arg host "$host" --arg protocol "$protocol" \
        --arg preferred "$preferred" --arg port "$port" --arg path "$path" --argjson only "$tunnel_only" '
        .argo += {enabled:true,mode:$mode,protocol:$protocol,hostname:$host,preferred_ip:$preferred,
                  local_port:($port|tonumber),xhttp_path:$path} |
        if $only then .inbound.mode="argo" | .inbound.hysteria.enabled=false else . end' "$KOKORO_CONFIG"
    kokoro_state_refresh_cfg
    if [[ $tunnel_only == true && -z $(kokoro_cfg '.role // ""') ]]; then
        source "$KOKORO_ROOT/lib/xray.sh"
        source "$KOKORO_ROOT/lib/keys.sh"
        kokoro_validate_service_paths
        kokoro_cfg_set_str '.role' edge
        kokoro_xray_install
        kokoro_gen_edge_secrets
    fi
    if [[ $mode == named ]]; then printf '%s http://127.0.0.1:%s\n' "$(kokoro_cf_text argo_origin)" "$port"; fi
}
