#!/usr/bin/env bash
# kokoro-xray — VLESS share links + terminal QR

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

kokoro_link_tls_url() {
    kokoro_ensure_state
    local uuid path mode cdn
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "tls" || "$mode" == "both" ]] || return 0
    uuid="$(kokoro_sec '.inbound.uuid')"
    path="$(kokoro_sec '.inbound.xhttp_path')"
    cdn="$(kokoro_cfg '.inbound.tls.cdn_domain')"
    [[ -n "$cdn" && "$cdn" != "null" ]] || return 0
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&path=%s&host=%s&sni=%s&fp=chrome&alpn=h2#kokoro-tls\n' \
        "$uuid" "$cdn" "$path" "$cdn" "$cdn"
}

kokoro_link_reality_url() {
    kokoro_ensure_state
    local uuid path sni pub sid mode host
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "reality" || "$mode" == "both" ]] || return 0
    uuid="$(kokoro_sec '.inbound.uuid')"
    path="$(kokoro_sec '.inbound.xhttp_path')"
    sni="$(kokoro_cfg '.inbound.reality.server_names[0]')"
    pub="$(kokoro_sec '.inbound.reality.public_key')"
    sid="$(kokoro_sec '.inbound.reality.short_ids[0]')"
    host="$(curl -4 -s ifconfig.me 2>/dev/null || echo 'YOUR_VPS_IP')"
    printf 'vless://%s@%s:443?encryption=none&security=reality&type=xhttp&path=%s&pbk=%s&fp=chrome&sni=%s&sid=%s#kokoro-reality\n' \
        "$uuid" "$host" "$path" "$pub" "$sni" "$sid"
}

kokoro_link_tls_json() {
    kokoro_ensure_state
    local uuid path mode cdn
    mode="$(kokoro_cfg '.inbound.mode')"
    [[ "$mode" == "tls" || "$mode" == "both" ]] || return 1
    uuid="$(kokoro_sec '.inbound.uuid')"
    path="$(kokoro_sec '.inbound.xhttp_path')"
    cdn="$(kokoro_cfg '.inbound.tls.cdn_domain')"
    [[ -n "$cdn" && "$cdn" != "null" ]] || return 1

    jq -n \
        --arg uuid "$uuid" \
        --arg path "$path" \
        --arg cdn "$cdn" \
        '{
          log: { loglevel: "warning" },
          dns: {
            servers: [
              "https://cloudflare-dns.com/dns-query",
              "https://1.1.1.1/dns-query",
              "https://base.dns.mullvad.net/dns-query",
              "https://extended.dns.mullvad.net/dns-query"
            ],
            queryStrategy: "UseIPv4"
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
              tag: "kokoro-tls",
              protocol: "vless",
              settings: {
                vnext: [
                  {
                    address: $cdn,
                    port: 443,
                    users: [
                      {
                        id: $uuid,
                        encryption: "none",
                        flow: ""
                      }
                    ]
                  }
                ]
              },
              streamSettings: {
                network: "xhttp",
                security: "tls",
                tlsSettings: {
                  serverName: $cdn,
                  fingerprint: "chrome",
                  alpn: ["h2"]
                },
                xhttpSettings: {
                  path: $path,
                  host: $cdn,
                  mode: "auto",
                  xmux: {
                    maxConnections: "6",
                    hMaxRequestTimes: "600-900",
                    hMaxReusableSecs: "1800-3000"
                  },
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
              }
            },
            { tag: "DIRECT", protocol: "freedom" },
            { tag: "BLOCK", protocol: "blackhole" }
          ],
          routing: {
            domainStrategy: "IPIfNonMatch",
            rules: [
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
                outboundTag: "kokoro-tls"
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
                protocol: ["bittorrent"],
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
                outboundTag: "kokoro-tls"
              }
            ]
          }
        }'
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
    local show_qr=false json_tls=false
    local reality_url tls_url

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --qr) show_qr=true; shift ;;
            --json)
                if [[ $# -ge 2 && "${2:-}" != -* ]]; then
                    [[ "$2" == "tls" ]] || kokoro_die "unknown JSON profile: $2 (expected tls)"
                    json_tls=true
                    shift 2
                else
                    json_tls=true
                    shift
                fi
                ;;
            -h|--help)
                cat <<'EOF'
kokoro-xray link — VLESS share URLs

Usage:
  kokoro-xray link
  kokoro-xray link --qr
  kokoro-xray link --json [tls]

Options:
  --qr            Print terminal QR codes (requires qrencode)
  --json [tls]    Print full Xray client JSON for kokoro-tls
EOF
                return 0
                ;;
            *) kokoro_die "unknown option: $1 (try --help)" ;;
        esac
    done

    if [[ "$json_tls" == "true" ]]; then
        kokoro_link_tls_json || kokoro_die "tls profile is unavailable for current mode"
        return 0
    fi

    reality_url="$(kokoro_link_reality_url)"
    tls_url="$(kokoro_link_tls_url)"

    [[ -n "$reality_url" || -n "$tls_url" ]] || kokoro_die "no links for role/mode (edge required)"

    if [[ -n "$reality_url" ]]; then
        printf '%s\n' "$reality_url"
        [[ "$show_qr" == "true" ]] && kokoro_link_qr "$reality_url" "REALITY"
    fi

    if [[ -n "$tls_url" ]]; then
        printf '%s\n' "$tls_url"
        [[ "$show_qr" == "true" ]] && kokoro_link_qr "$tls_url" "TLS"
    fi
}
