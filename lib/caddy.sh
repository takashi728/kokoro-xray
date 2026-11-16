#!/usr/bin/env bash
# kokoro-xray — Caddy with caddy-l4 via xcaddy

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
       ( "$mode" == "both" || ( "$mode" == "reality" && "$hysteria" == "true" ) ) ]]
}

kokoro_caddy_installed_matches() {
    local dest="$1" version="$2" installed
    [[ -x "$dest" ]] || return 1
    installed="$("$dest" version 2>/dev/null | awk '{print $1}')"
    [[ "$installed" == "$version" ]] || return 1
    if kokoro_caddy_needs_l4; then
        "$dest" list-modules 2>/dev/null | grep -q 'layer4' || return 1
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
    curl -fsSL "$url" -o "${3}/go.tgz"
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

kokoro_caddy_install() {
    local dest caddy_version go_bin go_path staged
    kokoro_need_root
    dest="$(kokoro_cfg '.paths.caddy_bin')"
    caddy_version="$(kokoro_caddy_version)"

    if kokoro_caddy_installed_matches "$dest" "$caddy_version"; then
        kokoro_log "caddy ${caddy_version} already installed"
        kokoro_caddy_install_service
        return
    fi

    kokoro_pkg_install curl git ca-certificates tar
    kokoro_build_env
    kokoro_go_for_caddy
    go_bin="$KOKORO_CADDY_GO_BIN"
    go_path="$(dirname "$go_bin"):${PATH}"
    PATH="$go_path"
    staged="${dest}.new.$$"
    rm -f "$staged"
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

    [[ -f "$staged" ]] || kokoro_die "caddy build did not create $staged"
    chmod 755 "$staged"
    [[ "$("$staged" version 2>/dev/null | awk '{print $1}')" == "$caddy_version" ]] ||
        kokoro_die "built Caddy version does not match ${caddy_version}"
    if kokoro_caddy_needs_l4; then
        "$staged" list-modules 2>/dev/null | grep -q 'layer4' || kokoro_die "caddy-l4 module missing after xcaddy build"
    fi
    mv "$staged" "$dest"
    kokoro_log "caddy ${caddy_version} installed to ${dest}"
    kokoro_caddy_install_service
}

kokoro_caddy_install_service() {
    local caddy_bin caddyfile
    caddy_bin="$(kokoro_cfg '.paths.caddy_bin')"
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    install -d "$(dirname "$caddyfile")"
    cat >/etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy Service (kokoro-xray)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${caddy_bin} run --environ --config ${caddyfile}
ExecReload=${caddy_bin} reload --config ${caddyfile} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable caddy >/dev/null 2>&1 || true
}

kokoro_hysteria_prepare_certificate() {
    [[ "$(kokoro_cfg '.inbound.hysteria.enabled // false')" == "true" ]] || return 0

    local domain cert key i mode caddy_bin caddyfile stopped_xray=false
    domain="$(kokoro_cfg '.inbound.hysteria.domain' | tr '[:upper:]' '[:lower:]')"
    mode="$(kokoro_cfg '.inbound.mode')"
    caddy_bin="$(kokoro_cfg '.paths.caddy_bin')"
    caddyfile="$(kokoro_cfg '.paths.caddyfile')"
    install -d -m 700 /var/lib/kokoro-caddy
    kokoro_render_caddy
    "$caddy_bin" validate --config "$caddyfile" ||
        kokoro_die "invalid Caddy config for Hysteria2 certificate"

    if [[ "$mode" == "reality" ]] && systemctl is-active --quiet xray 2>/dev/null; then
        systemctl stop xray
        stopped_xray=true
    fi

    if ! systemctl restart caddy; then
        [[ "$stopped_xray" == "true" ]] && systemctl restart xray || true
        kokoro_die "caddy failed while requesting Hysteria2 certificate"
    fi

    kokoro_log "waiting for Let's Encrypt certificate: ${domain}"
    for i in $(seq 1 90); do
        cert="$(find /var/lib/kokoro-caddy/certificates -type f -path "*/${domain}/${domain}.crt" -print -quit 2>/dev/null)"
        key="$(find /var/lib/kokoro-caddy/certificates -type f -path "*/${domain}/${domain}.key" -print -quit 2>/dev/null)"
        if [[ -n "$cert" && -n "$key" ]] && openssl x509 -checkend 3600 -noout -in "$cert" >/dev/null 2>&1; then
            kokoro_cfg_set_str '.paths.hysteria_cert' "$cert"
            kokoro_cfg_set_str '.paths.hysteria_key' "$key"
            kokoro_log "Hysteria2 certificate ready"
            return 0
        fi
        sleep 2
    done

    if [[ "$stopped_xray" == "true" ]]; then
        systemctl stop caddy || true
        systemctl restart xray || true
    fi
    kokoro_die "certificate not issued; verify DNS points directly here and ports 80/tcp + 443/tcp are open"
}
