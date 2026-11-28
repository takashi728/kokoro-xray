#!/usr/bin/env bash
# kokoro-xray — Caddy downloads and xcaddy builds

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/os.sh"

KOKORO_XCADDY_VERSION="${KOKORO_XCADDY_VERSION:-v0.4.7}"
KOKORO_CADDY_L4_VERSION="${KOKORO_CADDY_L4_VERSION:-v0.1.3}"
KOKORO_GO_MIN_VERSION="${KOKORO_GO_MIN_VERSION:-1.26.9}"
KOKORO_GO_VERSION="${KOKORO_GO_VERSION:-1.26.11}"
KOKORO_GO_PREFIX="${KOKORO_GO_PREFIX:-/usr/local/kokoro-go}"

kokoro_caddy_version() {
    local version
    version="$(kokoro_cfg '.caddy.version')"
    [[ -n "$version" && "$version" != "null" ]] || kokoro_die "missing caddy.version"
    case "$version" in
        v*) printf '%s\n' "$version" ;;
        *) printf 'v%s\n' "$version" ;;
    esac
}

kokoro_caddy_needs_l4() {
    local mode use_l4 hysteria
    mode="$(kokoro_cfg '.inbound.mode')"
    use_l4="$(kokoro_cfg '.caddy.use_l4')"
    hysteria="$(kokoro_cfg '.inbound.hysteria.enabled // false')"
    [[ "$use_l4" == "true" &&
       ( "$mode" == "both" || ( "$mode" == "reality" && "$hysteria" == "true" ) ||
         ( "$(kokoro_cfg '.inbound.transport // "xhttp"')" == raw && "$mode" == tls ) ) ]]
}

kokoro_caddy_installed_matches() {
    local dest="$1" version="$2" installed
    [[ -x "$dest" ]] || return 1
    installed="$("$dest" version 2>/dev/null | awk '{print $1}')"
    [[ "$installed" == "$version" ]] || return 1
    if kokoro_caddy_needs_l4; then
        "$dest" list-modules 2>/dev/null | grep -Fx 'layer4' >/dev/null || return 1
    fi
    return 0
}

kokoro_run_with_timer() {
    local label="$1" interval="${KOKORO_BUILD_TIMER_INTERVAL:-30}" pid elapsed status
    shift

    "$@" &
    pid="$!"
    elapsed=0

    while kill -0 "$pid" 2>/dev/null; do
        sleep "$interval"
        if kill -0 "$pid" 2>/dev/null; then
            elapsed=$((elapsed + interval))
            kokoro_log "${label} still running... ${elapsed}s"
        fi
    done

    if wait "$pid"; then
        return 0
    fi
    status=$?
    return "$status"
}

# Phase 2: seam for external build commands. Tests set KOKORO_RUNNER to a fake.
kokoro_run_cmd() { # label cmd...
    local label="$1"
    shift
    if [[ -n "${KOKORO_RUNNER:-}" ]]; then
        "${KOKORO_RUNNER}" "$label" "$@"
    else
        kokoro_run_with_timer "$label" "$@"
    fi
}

# Pure: given cpus/mem_mb, emit Go build env assignments that keep the Caddy
# compile inside memory on small VPSes (1-3GB, single core, slow Intel).
#   cpus<=2          -> build one package at a time (GOFLAGS=-p=1)
#   mem<=3GB         -> GOGC=25 + GOMEMLIMIT=75% (tight heap, no OOM)
#   mem<=6GB         -> GOGC=50 + GOMEMLIMIT=75%
kokoro_build_tuning() { # cpus mem_mb -> env lines
    local cpus="$1" mem_mb="$2"
    local goflags=""
    if (( cpus <= 2 )); then
        goflags="-p=1"
    fi
    printf 'GOFLAGS=%s\n' "$goflags"
    if (( mem_mb <= 3072 )); then
        printf 'GOGC=25\n'
        printf 'GOMEMLIMIT=%dMiB\n' $(( mem_mb * 75 / 100 ))
    elif (( mem_mb <= 6144 )); then
        printf 'GOGC=50\n'
        printf 'GOMEMLIMIT=%dMiB\n' $(( mem_mb * 75 / 100 ))
    fi
}

kokoro_build_env() {
    local cpus mem_mb line
    cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
    [[ "$cpus" =~ ^[0-9]+$ ]] || cpus=1
    [[ "$mem_mb" =~ ^[0-9]+$ ]] || mem_mb=1024

    while IFS= read -r line; do
        [[ -n "$line" ]] && export "$line"
    done < <(kokoro_build_tuning "$cpus" "$mem_mb")

    if (( mem_mb <= 2048 )) && ! awk 'NR>1 && $1!=""' /proc/swaps 2>/dev/null | grep -q .; then
        kokoro_warn "only ${mem_mb}MB RAM and no swap — Go build may OOM; add swap: fallocate -l 2G /swapfile && mkswap /swapfile && swapon /swapfile"
    fi
}

kokoro_version_ge() {
    local have="$1" need="$2"
    local hm hn hp nm nn np
    IFS=. read -r hm hn hp <<<"$have"
    IFS=. read -r nm nn np <<<"$need"
    hp="${hp:-0}"; np="${np:-0}"
    [[ "$hm" =~ ^[0-9]+$ && "$hn" =~ ^[0-9]+$ && "$hp" =~ ^[0-9]+$ ]] || return 1
    [[ "$nm" =~ ^[0-9]+$ && "$nn" =~ ^[0-9]+$ && "$np" =~ ^[0-9]+$ ]] || return 1
    (( hm > nm )) && return 0
    (( hm < nm )) && return 1
    (( hn > nn )) && return 0
    (( hn < nn )) && return 1
    (( hp >= np ))
}

kokoro_go_version() {
    local go_bin="$1" raw
    raw="$("$go_bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//; s/[^0-9.].*$//')"
    [[ -n "$raw" ]] && printf '%s\n' "$raw"
}

kokoro_go_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        *) kokoro_die "unsupported Go architecture: $(uname -m)" ;;
    esac
}

kokoro_go_sha256() { # version arch
    if [[ "$1" == "1.26.11" ]]; then
        case "$2" in
            amd64) printf '%s\n' "9849f4e04ee35303714e34fbc3ac8ab44ea3e448a95aa182f91e3b9b79c710ec" ;;
            arm64) printf '%s\n' "6c2f29b458b5add0835f18b776f69c8881a6d88428f1484a6da55755e620757e" ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

kokoro_go_download() { # version arch tmp
    local sha url="https://go.dev/dl/go${1}.linux-${2}.tar.gz"
    sha="$(kokoro_go_sha256 "$1" "$2")" ||
        kokoro_die "no pinned SHA-256 for Go ${1} linux-${2}"
    curl --proto '=https' --proto-redir '=https' -fsSL "$url" -o "${3}/go.tgz" || return 1
    printf '%s  %s\n' "$sha" "${3}/go.tgz" | sha256sum -c - >/dev/null
}

kokoro_go_install_official() {
    local arch tmp prefix go_bin version go_version
    arch="$(kokoro_go_arch)"
    go_version="$KOKORO_GO_VERSION"
    prefix="${KOKORO_GO_PREFIX}/go${go_version}"
    go_bin="${prefix}/bin/go"

    if [[ -x "$go_bin" ]]; then
        version="$(kokoro_go_version "$go_bin")"
        if kokoro_version_ge "$version" "$KOKORO_GO_MIN_VERSION"; then
            KOKORO_CADDY_GO_BIN="$go_bin"
            return 0
        fi
    fi

    kokoro_pkg_install curl git ca-certificates tar
    tmp="$(mktemp -d)"

    kokoro_log "installing Go ${KOKORO_GO_VERSION} for Caddy build"
    kokoro_go_download "$go_version" "$arch" "$tmp" ||
        kokoro_die "failed to download Go ${go_version}"
    tar -C "$tmp" -xzf "${tmp}/go.tgz" || kokoro_die "failed to extract Go ${go_version}"
    install -d "$KOKORO_GO_PREFIX"
    if [[ -e "$prefix" ]]; then
        mv "$prefix" "${prefix}.old.$$"
    fi
    if [[ ! -x "${tmp}/go/bin/go" ]]; then
        [[ -e "${prefix}.old.$$" ]] && mv "${prefix}.old.$$" "$prefix"
        rm -rf "$tmp"
        kokoro_die "Go install failed: staged binary missing"
    fi
    if ! mv "${tmp}/go" "$prefix"; then
        [[ -e "${prefix}.old.$$" ]] && mv "${prefix}.old.$$" "$prefix"
        rm -rf "$tmp"
        kokoro_die "failed to install Go ${go_version}"
    fi
    rm -rf "${prefix}.old.$$" "$tmp"
    [[ -x "$go_bin" ]] || kokoro_die "Go install failed: $go_bin missing"
    KOKORO_CADDY_GO_BIN="$go_bin"
}

kokoro_go_for_caddy() {
    local go_bin version
    if go_bin="$(command -v go 2>/dev/null)"; then
        version="$(kokoro_go_version "$go_bin")"
        if kokoro_version_ge "$version" "$KOKORO_GO_MIN_VERSION"; then
            kokoro_log "using Go ${version} for Caddy build"
            KOKORO_CADDY_GO_BIN="$go_bin"
            return 0
        fi
        kokoro_warn "system Go ${version:-unknown} is too old; need >= ${KOKORO_GO_MIN_VERSION}"
    fi

    kokoro_go_install_official
    version="$(kokoro_go_version "$KOKORO_CADDY_GO_BIN")"
    kokoro_log "using Go ${version} for Caddy build"
}

kokoro_caddy_l4_sha256() { # caddy-version-l4-version arch
    case "$1/$2" in
        v2.11.9-v0.1.3/amd64) printf '%s\n' ea47e309445d507be7101e1a3500b75d3962aa9aa64d208c369b46e83db4a512 ;;
        v2.11.9-v0.1.3/arm64) printf '%s\n' 281ba043991d4b1f6ef4e7f05dbab3b3fe0eab7c49afc8751fffd6af939ae334 ;;
        *) return 1 ;;
    esac
}

kokoro_caddy_download() { # version staged-binary
    local version="$1" staged="$2" arch filename digest url archive release
    arch="$(kokoro_go_arch)" || return 1
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    if kokoro_caddy_needs_l4; then
        digest="$(kokoro_caddy_l4_sha256 "${version}-${KOKORO_CADDY_L4_VERSION}" "$arch")" || return 1
        release="caddy-l4-${version}-${KOKORO_CADDY_L4_VERSION}"
        filename="caddy-linux-${arch}.tar.gz"
        url="https://github.com/takashi728/kokoro-xray/releases/download/${release}/${filename}"
    else
        [[ "$version" == v2.11.9 ]] || return 1
        filename="caddy_${version#v}_linux_${arch}.tar.gz"
        url="https://github.com/caddyserver/caddy/releases/download/${version}/${filename}"
        case "$arch" in
            amd64) digest=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb ;;
            arm64) digest=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165 ;;
        esac
    fi
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    archive="$(mktemp "${staged}.archive.XXXXXX")" || return 1
    if curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$archive" &&
        printf '%s  %s\n' "$digest" "$archive" | sha256sum -c --status &&
        tar -xOzf "$archive" caddy >"$staged"; then
        rm -f -- "$archive"
        return 0
    fi
    rm -f -- "$archive"
    return 1
}

kokoro_caddy_install() (
    local dest caddy_version staged cleanup
    kokoro_need_root
    kokoro_validate_service_paths
    dest="$(kokoro_cfg '.paths.caddy_bin')"
    caddy_version="$(kokoro_caddy_version)"

    if kokoro_caddy_installed_matches "$dest" "$caddy_version"; then
        kokoro_log "caddy ${caddy_version} already installed"
        kokoro_caddy_install_service
        return
    fi

    staged="$(mktemp "${dest}.new.XXXXXX")" || return 1
    printf -v cleanup 'rm -f -- %q' "$staged"
    trap "$cleanup" EXIT
    if kokoro_small_vps; then
        kokoro_log "downloading prebuilt Caddy ${caddy_version}"
        if ! kokoro_caddy_download "$caddy_version" "$staged"; then
            kokoro_die "verified prebuilt Caddy unavailable; install a matching binary from a trusted source and retry"
        fi
    else
        kokoro_caddy_build "$caddy_version" "$staged" || return 1
    fi

    if ! chmod 755 "$staged" || ! kokoro_caddy_installed_matches "$staged" "$caddy_version"; then
        kokoro_die "staged Caddy version or required modules did not match"
    fi
    mv -T -- "$staged" "$dest" || return 1
    trap - EXIT
    kokoro_log "caddy ${caddy_version} installed to ${dest}"
    kokoro_caddy_install_service
)

kokoro_caddy_build() {
    local caddy_version="$1" staged="$2" go_bin go_path
    kokoro_pkg_install curl git ca-certificates tar || return 1
    kokoro_build_env
    kokoro_go_for_caddy || return 1
    go_bin="$KOKORO_CADDY_GO_BIN"
    go_path="$(dirname "$go_bin"):${PATH}"
    PATH="$go_path"
    export GOBIN=/usr/local/bin
    kokoro_run_cmd "install xcaddy" "$go_bin" install "github.com/caddyserver/xcaddy/cmd/xcaddy@${KOKORO_XCADDY_VERSION}" \
        || kokoro_die "failed to install xcaddy ${KOKORO_XCADDY_VERSION}"
    [[ -x /usr/local/bin/xcaddy ]] || kokoro_die "xcaddy not found after install"

    if kokoro_caddy_needs_l4; then
        kokoro_log "building Caddy ${caddy_version} with caddy-l4 ${KOKORO_CADDY_L4_VERSION}"
        kokoro_log "this can take several minutes on small VPS instances"
        kokoro_run_cmd "caddy build" /usr/local/bin/xcaddy build "$caddy_version" --with "github.com/mholt/caddy-l4@${KOKORO_CADDY_L4_VERSION}" --output "$staged" \
            || kokoro_die "failed to build Caddy ${caddy_version}"
    else
        kokoro_log "building Caddy ${caddy_version}"
        kokoro_log "this can take several minutes on small VPS instances"
        kokoro_run_cmd "caddy build" /usr/local/bin/xcaddy build "$caddy_version" --output "$staged" \
            || kokoro_die "failed to build Caddy ${caddy_version}"
    fi

}

kokoro_caddy_install_service() {
    local caddyfile unit
    kokoro_validate_service_paths
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    install -d "$(dirname "$caddyfile")" || return 1
    kokoro_service_user kokoro-caddy
    if [[ ! -d /var/lib/kokoro-caddy || "$(stat -c %u /var/lib/kokoro-caddy)" == 0 ]]; then
        printf '%s\n' 'd /var/lib/kokoro-caddy 0700 kokoro-caddy kokoro-caddy -' \
            'Z /var/lib/kokoro-caddy - kokoro-caddy kokoro-caddy -' |
            systemd-tmpfiles --create - || kokoro_die "cannot migrate Caddy storage"
    fi
    unit="$(kokoro_caddy_unit_content)" || return 1
    kokoro_install_systemd_unit caddy.service "$unit"
    systemctl daemon-reload || kokoro_die "cannot reload Caddy unit"
    systemctl enable caddy >/dev/null 2>&1 || true
}

kokoro_caddy_unit_content() {
    local caddy_bin caddyfile
    kokoro_validate_service_paths
    caddy_bin="$(kokoro_cfg '.paths.caddy_bin')"
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    cat <<EOF
[Unit]
Description=Caddy Service (kokoro-xray)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=kokoro-caddy
Group=kokoro-caddy
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
StateDirectory=kokoro-caddy
StateDirectoryMode=0700
Environment=HOME=/var/lib/kokoro-caddy
StandardInput=file:${caddyfile}
ExecStart=${caddy_bin} run --adapter caddyfile --config -
ExecReload=${caddy_bin} reload --adapter caddyfile --config - --force
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

kokoro_caddy_restore_after_certificate() { # backup directory, prior Caddy state, stopped Xray, config path
    local backup="$1" caddy_active="$2" stopped_xray="$3" caddyfile="$4"
    if [[ -f "$backup/Caddyfile" ]]; then
        cp "$backup/Caddyfile" "$caddyfile"
    else
        rm -f "$caddyfile"
    fi
    if [[ "$caddy_active" == true ]]; then
        systemctl restart caddy || kokoro_warn "failed to restore previous Caddy service"
    else
        systemctl stop caddy || true
    fi
    if [[ "$stopped_xray" == true ]]; then
        systemctl restart xray || kokoro_warn "failed to restore previous Xray service"
    fi
    rm -rf "$backup"
}

kokoro_caddy_prepare_certificate() { # domain, certificate state prefix
    local domain="$1" state_prefix="$2" cert key i mode caddy_bin caddyfile stopped_xray=false cert_root
    local canonical_cert canonical_key cert_mode key_mode
    local backup caddy_active=false xray_config
    kokoro_validate_service_paths
    domain="${domain,,}"
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
        kokoro_die "invalid certificate domain: $domain"
    [[ "$state_prefix" == tls || "$state_prefix" == hysteria ]] ||
        kokoro_die "invalid certificate state prefix"
    mode="$(kokoro_cfg '.inbound.mode')"
    caddy_bin="$(kokoro_cfg '.paths.caddy_bin')"
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    cert_root="$(realpath -m -- "$(kokoro_hysteria_cert_root)")"
    backup="$(mktemp -d)"
    [[ ! -f "$caddyfile" ]] || cp "$caddyfile" "$backup/Caddyfile"
    if systemctl is-active --quiet caddy 2>/dev/null; then caddy_active=true; fi
    if ! kokoro_render_caddy || ! kokoro_service_validate kokoro-caddy "$caddyfile" \
        env HOME=/var/lib/kokoro-caddy "$caddy_bin" validate --adapter caddyfile --config -; then
        kokoro_caddy_restore_after_certificate "$backup" "$caddy_active" false "$caddyfile"
        kokoro_die "invalid Caddy config for Xray certificate"
    fi

    xray_config="$(kokoro_cfg '.paths.xray_config')"
    if systemctl is-active --quiet xray 2>/dev/null; then
        if [[ "$mode" == reality ]] || jq -e 'any(.inbounds[]?;
            .protocol == "vless" and .port == 443 and .listen != "127.0.0.1")' "$xray_config" >/dev/null 2>&1; then
            systemctl stop xray
            stopped_xray=true
        fi
    fi

    if ! systemctl restart caddy; then
        kokoro_caddy_restore_after_certificate "$backup" "$caddy_active" "$stopped_xray" "$caddyfile"
        kokoro_die "caddy failed while requesting Xray certificate"
    fi

    kokoro_log "waiting for Let's Encrypt certificate: ${domain}"
    for i in $(seq 1 90); do
        cert="$(find "$cert_root" -type f -name "${domain}.crt" -print -quit 2>/dev/null)"
        key="$(find "$cert_root" -type f -name "${domain}.key" -print -quit 2>/dev/null)"
        if [[ -n "$cert" && -n "$key" ]]; then
            canonical_cert="$(realpath -e -- "$cert")"
            canonical_key="$(realpath -e -- "$key")"
            [[ "$canonical_cert" == "${cert_root}/"* && "$canonical_key" == "${cert_root}/"* ]] ||
                continue
            local owner caddy_uid
            caddy_uid="$(id -u kokoro-caddy 2>/dev/null || true)"
            for owner in "$canonical_cert" "$canonical_key"; do
                owner="$(stat -c %u "$owner")" || continue 2
                [[ "$owner" == 0 || "$owner" == "$caddy_uid" ]] || continue 2
            done
            cert_mode="$(stat -c '%a' "$canonical_cert")"
            key_mode="$(stat -c '%a' "$canonical_key")"
            (( (8#${cert_mode} & 8#022) == 0 &&
               (8#${key_mode} & 8#022) == 0 )) ||
                continue
            if (( EUID == 0 )); then
                runuser -u kokoro-caddy -- openssl x509 -checkend 3600 -noout -in "$canonical_cert" >/dev/null 2>&1 || continue
            else
                openssl x509 -checkend 3600 -noout -in "$canonical_cert" >/dev/null 2>&1 || continue
            fi
            kokoro_caddy_restore_after_certificate "$backup" "$caddy_active" "$stopped_xray" "$caddyfile"
            kokoro_cfg_set_str ".paths.${state_prefix}_cert" "$canonical_cert"
            kokoro_cfg_set_str ".paths.${state_prefix}_key" "$canonical_key"
            kokoro_log "${state_prefix} certificate ready"
            return 0
        fi
        sleep 2
    done

    kokoro_caddy_restore_after_certificate "$backup" "$caddy_active" "$stopped_xray" "$caddyfile"
    kokoro_die "certificate not issued; verify DNS points directly here and ports 80/tcp + 443/tcp are open"
}

kokoro_hysteria_prepare_certificate() {
    [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == true ]] || return 0
    kokoro_caddy_prepare_certificate "$(kokoro_cfg '.inbound.hysteria.domain')" hysteria
}

kokoro_tls_prepare_certificate() {
    kokoro_raw_tls_enabled || return 0
    [[ "$(kokoro_cfg '.caddy.use_l4')" == true ]] || kokoro_die "RAW TLS requires caddy.use_l4=true"
    kokoro_caddy_prepare_certificate "$(kokoro_tls_domain)" tls
}
