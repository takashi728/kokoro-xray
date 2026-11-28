#!/usr/bin/env bash
# kokoro-xray — VLESS share links + terminal QR

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"
source "${KOKORO_ROOT}/lib/cloudflare.sh"
source "${KOKORO_ROOT}/lib/argo.sh"

kokoro_link_vless_encryption() {
    if [[ "${1:-}" == tls ]] && kokoro_raw_tls_enabled; then
        printf 'none\n'
        return 0
    fi
    if [[ "$(kokoro_cfg '.inbound.vless_encryption.enabled // false')" == "true" ]]; then
        kokoro_sec '.inbound.vless_encryption.encryption'
    else
        printf 'none\n'
    fi
}

kokoro_link_public_address() {
    if [[ -n "${KOKORO_PUBLIC_ADDRESS:-}" ]]; then
        printf '%s\n' "$KOKORO_PUBLIC_ADDRESS"
        return 0
    fi
    curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || printf 'YOUR_VPS_IP\n'
}

kokoro_link_tls_url() {
    kokoro_ensure_state
    local uuid path mode cdn encryption
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "tls" || "$mode" == "both" ]] || return 0
    uuid="$(kokoro_sec '.inbound.uuid')"
    path="$(kokoro_sec '.inbound.xhttp_path')"
    cdn="$(kokoro_tls_domain)"
    encryption="$(kokoro_link_vless_encryption tls)"
    [[ -n "$cdn" && "$cdn" != "null" ]] || return 0
    if [[ "$(kokoro_cfg '.inbound.transport // "xhttp"')" == raw ]]; then
        printf 'vless://%s@%s:443?encryption=%s&security=tls&type=tcp&flow=xtls-rprx-vision-udp443&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1#kokoro-raw-tls\n' \
            "$uuid" "$cdn" "$encryption" "$cdn"
        return 0
    fi
    printf 'vless://%s@%s:443?encryption=%s&security=tls&type=xhttp&path=%s&host=%s&sni=%s&fp=chrome&alpn=h2#kokoro-tls\n' \
        "$uuid" "$cdn" "$encryption" "$path" "$cdn" "$cdn"
}

kokoro_link_reality_url() {
    kokoro_ensure_state
    local uuid path sni pub sid mode host encryption
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "reality" || "$mode" == "both" ]] || return 0
    uuid="$(kokoro_sec '.inbound.uuid')"
    path="$(kokoro_sec '.inbound.xhttp_path')"
    sni="$(kokoro_cfg '.inbound.reality.server_names[0]')"
    pub="$(kokoro_sec '.inbound.reality.public_key')"
    sid="$(kokoro_sec '.inbound.reality.short_ids[0]')"
    encryption="$(kokoro_link_vless_encryption)"
    host="$(kokoro_link_public_address)"
    if [[ "$(kokoro_cfg '.inbound.transport // "xhttp"')" == raw ]]; then
        [[ "$host" == *:* ]] && host="[$host]"
        printf 'vless://%s@%s:443?encryption=%s&security=reality&type=tcp&flow=xtls-rprx-vision-udp443&pbk=%s&fp=chrome&sni=%s&sid=%s#kokoro-raw-reality\n' \
            "$uuid" "$host" "$encryption" "$pub" "$sni" "$sid"
        return 0
    fi
    printf 'vless://%s@%s:443?encryption=%s&security=reality&type=xhttp&path=%s&pbk=%s&fp=chrome&sni=%s&sid=%s#kokoro-reality\n' \
        "$uuid" "$host" "$encryption" "$path" "$pub" "$sni" "$sid"
}

kokoro_link_hysteria_url() {
    kokoro_ensure_state
    [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]] || return 0
    local auth obfs domain ports primary_port encoded_ports interval hop_interval
    auth="$(kokoro_sec '.inbound.hysteria.auth')"
    obfs="$(kokoro_sec '.inbound.hysteria.obfs_password')"
    domain="$(kokoro_cfg '.inbound.hysteria.domain')"
    ports="$(kokoro_cfg '.inbound.hysteria.ports' | tr -d '[:space:]')"
    primary_port="${ports%%,*}"
    primary_port="${primary_port%%-*}"
    encoded_ports="$(jq -rn --arg value "$ports" '$value | @uri')"
    interval="$(kokoro_cfg '.inbound.hysteria.hop_interval')"
    hop_interval="${interval%%-*}"
    [[ -n "$auth" && -n "$obfs" && -n "$domain" ]] || return 0
    printf 'hysteria2://%s@%s:%s/?obfs=salamander&obfs-password=%s&sni=%s&mport=%s&port=%s&mportHopInt=%s#kokoro-hysteria2\n' \
        "$auth" "$domain" "$primary_port" "$obfs" "$domain" \
        "$encoded_ports" "$encoded_ports" "$hop_interval"
}

kokoro_link_hysteria_json() {
    kokoro_ensure_state
    [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]] || return 1
    local auth obfs domain ports primary_port interval congestion profile
    auth="$(kokoro_sec '.inbound.hysteria.auth')"
    obfs="$(kokoro_sec '.inbound.hysteria.obfs_password')"
    domain="$(kokoro_cfg '.inbound.hysteria.domain')"
    ports="$(kokoro_cfg '.inbound.hysteria.ports' | tr -d '[:space:]')"
    primary_port="${ports%%,*}"
    primary_port="${primary_port%%-*}"
    interval="$(kokoro_cfg '.inbound.hysteria.hop_interval')"
    congestion="$(kokoro_cfg '.inbound.hysteria.congestion')"
    profile="$(kokoro_cfg '.inbound.hysteria.bbr_profile')"
    [[ -n "$auth" && -n "$obfs" && -n "$domain" ]] || return 1

    jq -n \
        --arg auth "$auth" \
        --arg obfs "$obfs" \
        --arg domain "$domain" \
        --arg port "$primary_port" \
        --arg ports "$ports" \
        --arg interval "$interval" \
        --arg congestion "$congestion" \
        --arg profile "$profile" \
        '{
          log: { loglevel: "warning" },
          inbounds: [
            {
              tag: "socks-in",
              listen: "127.0.0.1",
              port: 10808,
              protocol: "socks",
              settings: { udp: true }
            },
            {
              tag: "http-in",
              listen: "127.0.0.1",
              port: 10809,
              protocol: "http"
            }
          ],
          outbounds: [
            {
              tag: "kokoro-hysteria2",
              protocol: "hysteria",
              settings: {
                version: 2,
                address: $domain,
                port: ($port | tonumber)
              },
              streamSettings: {
                method: "hysteria",
                network: "hysteria",
                security: "tls",
                tlsSettings: {
                  serverName: $domain,
                  alpn: ["h3"],
                  fingerprint: "chrome"
                },
                hysteriaSettings: {
                  version: 2,
                  auth: $auth,
                  udpIdleTimeout: 60
                },
                finalmask: {
                  udp: [
                    {
                      type: "salamander",
                      settings: {
                        password: $obfs
                      }
                    },
                    {
                      type: "udphop",
                      settings: {
                        mode: "intervalremote",
                        interval: $interval,
                        remotePorts: $ports
                      }
                    }
                  ],
                  quicParams: {
                    congestion: $congestion,
                    bbrProfile: $profile
                  }
                }
              }
            }
          ],
          routing: {
            domainStrategy: "IPIfNonMatch",
            rules: [{ type: "field", network: "tcp,udp", outboundTag: "kokoro-hysteria2" }]
          }
        }'
}

kokoro_link_vless_json() {
    local address="$1" tag="$2" security="$3" server_name="$4"
    local public_key="$5" short_id="$6" path="$7" uuid="$8" encryption="$9"

    jq -n \
        --arg address "$address" \
        --arg tag "$tag" \
        --arg security "$security" \
        --arg server_name "$server_name" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg path "$path" \
        --arg uuid "$uuid" \
        --arg encryption "$encryption" \
        --arg transport "${10:-$(kokoro_cfg '.inbound.transport // "xhttp"')}" \
        --arg argo_mode "${11:-auto}" \
        '
          def xhttp_base_settings:
            {
              path: $path,
              xmux: {
                maxConcurrency: 1,
                hMaxRequestTimes: "600-900",
                hMaxReusableSecs: "1800-3000"
              }
            };

          def xhttp_settings:
            if $tag == "kokoro-argo" then
              {path:$path, host:$server_name, mode:$argo_mode}
            elif $security == "tls" then
              xhttp_base_settings + {
                host: $server_name,
                mode: "auto",
                sessionIDTable: "Base62",
                sessionIDLength: "22-26",
                xPaddingKey: "v",
                xPaddingBytes: "16-96",
                xPaddingHeader: "Referer",
                xPaddingMethod: "tokenish",
                uplinkHTTPMethod: "POST",
                xPaddingObfsMode: true,
                xPaddingPlacement: "queryInHeader",
                scMaxEachPostBytes: 2000000,
                uplinkDataPlacement: "body",
                scMinPostsIntervalMs: 10
              }
            elif $security == "reality" then
              xhttp_base_settings
            else
              error("unsupported XHTTP client security: \($security)")
            end;

          def stream_settings:
            if $security == "tls" then
              {
                network: $transport,
                security: "tls",
                tlsSettings: {
                  serverName: $server_name,
                  fingerprint: "chrome",
                  alpn: (if $transport == "raw" then ["h2", "http/1.1"] else ["h2"] end)
                }
              } + (if $transport == "xhttp" then {xhttpSettings: xhttp_settings} else {} end)
            elif $security == "reality" then
              {
                network: $transport,
                security: "reality",
                realitySettings: {
                  serverName: $server_name,
                  fingerprint: "chrome",
                  publicKey: $public_key,
                  shortId: $short_id,
                  spiderX: "/"
                }
              } + (if $transport == "xhttp" then {xhttpSettings: xhttp_settings} else {} end)
            else
              error("unsupported XHTTP client security: \($security)")
            end;

          def routing_rules: [
            {
              type: "field",
              domain: ["geosite:category-ads-all"],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              domain: [
                "domain:dns.google",
                "domain:dns.google.com",
                "domain:doh.google",
                "domain:google-public-dns-a.google.com",
                "domain:google-public-dns-b.google.com"
              ],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              ip: [
                "8.8.8.8",
                "8.8.4.4",
                "2001:4860:4860::8888",
                "2001:4860:4860::8844"
              ],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              domain: [
                "geosite:google",
                "geosite:youtube",
                "domain:gmail.com",
                "domain:gemini.google.com",
                "domain:gemini.google",
                "domain:googleapis.cn",
                "domain:googleapis-cn.com",
                "domain:gstatic.cn",
                "domain:gstatic-cn.com"
              ],
              outboundTag: $tag
            },
            {
              type: "field",
              ip: ["geoip:private"],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              domain: ["geosite:private"],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              domain: [
                "geosite:cn",
                "geosite:geolocation-cn",
                "regexp:.*\\.ru$",
                "regexp:.*\\.su$",
                "regexp:.*\\.xn--p1ai$"
              ],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              ip: ["geoip:cn"],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              ip: ["geoip:ru"],
              outboundTag: "BLOCK"
            },
            {
              type: "field",
              network: "tcp,udp",
              outboundTag: $tag
            }
          ];

          {
            log: { loglevel: "warning" },
            dns: {
              servers: ["https://cloudflare-dns.com/dns-query"],
              queryStrategy: "UseIP"
            },
            inbounds: [
              {
                tag: "socks-in",
                listen: "127.0.0.1",
                port: 10808,
                protocol: "socks",
                settings: { udp: true }
              },
              {
                tag: "http-in",
                listen: "127.0.0.1",
                port: 10809,
                protocol: "http"
              }
            ],
            outbounds: [
              {
                tag: $tag,
                protocol: "vless",
                settings: {
                  vnext: [
                    {
                      address: $address,
                      port: 443,
                      users: [
                        {
                          id: $uuid,
                          encryption: $encryption,
                          flow: (if $transport == "raw" then "xtls-rprx-vision-udp443" else "" end)
                        }
                      ]
                    }
                  ]
                },
                streamSettings: stream_settings
              },
              { tag: "DIRECT", protocol: "freedom" },
              { tag: "BLOCK", protocol: "blackhole" }
            ],
            routing: {
              domainStrategy: "IPIfNonMatch",
              rules: routing_rules
            }
          }
        '
}

kokoro_link_tls_json() {
    kokoro_ensure_state
    local uuid path mode cdn encryption
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "tls" || "$mode" == "both" ]] || return 1
    uuid="$(kokoro_sec '.inbound.uuid')"
    path="$(kokoro_sec '.inbound.xhttp_path')"
    cdn="$(kokoro_tls_domain)"
    encryption="$(kokoro_link_vless_encryption tls)"
    [[ -n "$cdn" && "$cdn" != "null" ]] || return 1

    kokoro_link_vless_json "$cdn" "kokoro-tls" "tls" "$cdn" "" "" \
        "$path" "$uuid" "$encryption"
}

kokoro_link_reality_json() {
    kokoro_ensure_state
    local uuid path mode sni public_key short_id encryption address
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "reality" || "$mode" == "both" ]] || return 1
    uuid="$(kokoro_sec '.inbound.uuid')"
    path="$(kokoro_sec '.inbound.xhttp_path')"
    sni="$(kokoro_cfg '.inbound.reality.server_names[0]')"
    public_key="$(kokoro_sec '.inbound.reality.public_key')"
    short_id="$(kokoro_sec '.inbound.reality.short_ids[0]')"
    encryption="$(kokoro_link_vless_encryption)"
    address="$(kokoro_link_public_address)"
    [[ -n "$uuid" && -n "$sni" && -n "$public_key" && -n "$short_id" ]] ||
        return 1
    [[ "$(kokoro_cfg '.inbound.transport // "xhttp"')" == raw || -n "$path" ]] || return 1

    kokoro_link_vless_json "$address" "kokoro-reality" "reality" "$sni" \
        "$public_key" "$short_id" "$path" "$uuid" "$encryption"
}

kokoro_link_argo() {
    local format="$1" preferred="$2" hostname address path uuid encryption mode
    [[ $(kokoro_cfg '.argo.enabled // false') == true ]] || return 1
    kokoro_argo_validate || return 1
    if ! hostname="$(kokoro_argo_hostname)" || ! kokoro_cf_domain "$hostname"; then
        kokoro_warn "$(kokoro_cf_text argo_pending)"; return 1
    fi
    address="${preferred:-$(kokoro_cfg '.argo.preferred_ip')}"
    address="${address:-$hostname}"
    kokoro_cf_host "$address" || return 1
    path="$(kokoro_cfg '.argo.xhttp_path')"; mode="$(kokoro_cfg '.argo.xhttp_mode')"
    uuid="$(kokoro_sec '.inbound.uuid')"; encryption="$(kokoro_link_vless_encryption)"
    if [[ $format == json ]]; then
        kokoro_link_vless_json "$address" kokoro-argo tls "$hostname" "" "" "$path" "$uuid" "$encryption" xhttp "$mode"
    else
        [[ $address != *:* ]] || address="[$address]"
        jq -nr --arg address "$address" --arg host "$hostname" --arg path "$path" --arg mode "$mode" \
            --arg uuid "$uuid" --arg enc "$encryption" '
            "vless://\($uuid|@uri)@\($address):443?security=tls&type=xhttp&alpn=h2&fp=chrome&encryption=\($enc|@uri)&sni=\($host)&host=\($host)&path=\($path|@uri)&mode=\($mode)#kokoro-argo"'
    fi
}

kokoro_link_qr_ensure() {
    command -v qrencode >/dev/null 2>&1 && return 0
    if [[ "${EUID}" -eq 0 ]]; then
        # shellcheck source=lib/os.sh
        source "${KOKORO_ROOT}/lib/os.sh"
        kokoro_pkg_install qrencode
        return 0
    fi
    kokoro_die "qrencode not found — install qrencode or run as root"
}

kokoro_link_qr() {
    local url="$1" label="$2"
    [[ -n "$url" ]] || return 0
    kokoro_link_qr_ensure
    echo "--- ${label} (scan with client app) ---"
    printf '%s' "$url" | qrencode -t ANSIUTF8 -m 2
    echo ""
}

kokoro_link_show() {
    local show_qr=false json_profile=""
    local reality_url tls_url hysteria_url argo_url="" preferred=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --qr) show_qr=true; shift ;;
            --cf-ip)
                kokoro_cf_host "${2:-}" || kokoro_die "$(kokoro_cf_text argo_invalid)"
                preferred="$2"; shift 2 ;;
            --json)
                if [[ $# -ge 2 && "${2:-}" != -* ]]; then
                    [[ "$2" =~ ^(tls|reality|hysteria|argo)$ ]] ||
                        kokoro_die "unknown JSON profile: $2 (expected tls, reality, hysteria, or argo)"
                    json_profile="$2"
                    shift 2
                else
                    json_profile="tls"
                    shift
                fi
                ;;
            -h|--help)
                cat <<'EOF'
kokoro-xray link — proxy share URLs

Usage:
  kokoro-xray link
  kokoro-xray link --qr
  kokoro-xray link --json [tls|reality|hysteria|argo] [--cf-ip ADDRESS]

Options:
  --qr                    Print terminal QR codes (requires qrencode)
  --json [tls|reality|hysteria|argo]
                          Print a full Xray client JSON profile
EOF
                return 0
                ;;
            *) kokoro_die "unknown option: $1 (try --help)" ;;
        esac
    done

    case "$json_profile" in
        argo)
            kokoro_ensure_state
            kokoro_link_argo json "$preferred" || kokoro_die "$(kokoro_cf_text argo_pending)"
            return 0 ;;
        tls)
            kokoro_link_tls_json ||
                kokoro_die "tls profile is unavailable for current mode"
            return 0
            ;;
        reality)
            kokoro_link_reality_json ||
                kokoro_die "reality profile is unavailable for current mode"
            return 0
            ;;
        hysteria)
            kokoro_link_hysteria_json ||
                kokoro_die "hysteria profile is unavailable"
            return 0
            ;;
    esac

    reality_url="$(kokoro_link_reality_url)"
    tls_url="$(kokoro_link_tls_url)"
    hysteria_url="$(kokoro_link_hysteria_url)"
    if [[ $(kokoro_cfg '.argo.enabled // false') == true ]]; then
        argo_url="$(kokoro_link_argo url "$preferred")" || argo_url=""
    fi

    [[ -n "$reality_url" || -n "$tls_url" || -n "$hysteria_url" || -n "$argo_url" ]] ||
        kokoro_die "no links for role/mode (edge required)"

    if [[ -n "$reality_url" ]]; then
        printf '%s\n' "$reality_url"
        [[ "$show_qr" == "true" ]] && kokoro_link_qr "$reality_url" "REALITY"
    fi

    if [[ -n "$tls_url" ]]; then
        printf '%s\n' "$tls_url"
        [[ "$show_qr" == "true" ]] && kokoro_link_qr "$tls_url" "TLS"
    fi

    if [[ -n "$hysteria_url" ]]; then
        printf '%s\n' "$hysteria_url"
        [[ "$show_qr" == "true" ]] && kokoro_link_qr "$hysteria_url" "HYSTERIA2"
    fi
    if [[ -n $argo_url ]]; then
        printf '%s\n' "$argo_url"
        if [[ $show_qr == true ]]; then kokoro_link_qr "$argo_url" Argo; fi
    fi
}
