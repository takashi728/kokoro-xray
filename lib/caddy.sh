#!/usr/bin/env bash
# kokoro-xray — Caddy with caddy-l4 via xcaddy

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/os.sh"

KOKORO_XCADDY_VERSION="${KOKORO_XCADDY_VERSION:-v0.4.6}"
KOKORO_CADDY_L4_VERSION="${KOKORO_CADDY_L4_VERSION:-v0.1.1}"
KOKORO_GO_MIN_VERSION="${KOKORO_GO_MIN_VERSION:-1.25.0}"
KOKORO_GO_VERSION="${KOKORO_GO_VERSION:-1.26.5}"
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
    local mode use_l4
    mode="$(kokoro_cfg '.inbound.mode')"
    use_l4="$(kokoro_cfg '.caddy.use_l4')"
    [[ "$use_l4" == "true" && "$mode" == "both" ]]
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

kokoro_go_download() { # version arch tmp
    local url="https://go.dev/dl/go${1}.linux-${2}.tar.gz"
    curl -fsSL "$url" -o "${3}/go.tgz"
}

kokoro_go_first_downloadable() { # arch tmp -> version that downloads (or 1)
    local arch="$1" tmp="$2" v
    while IFS= read -r v; do
        v="${v#go}"
        [[ "$v" == "$KOKORO_GO_VERSION" ]] && continue
        if kokoro_go_download "$v" "$arch" "$tmp"; then
            printf '%s' "$v"
            return 0
        fi
    done < <(curl -fsSL "https://go.dev/dl/?mode=json" 2>/dev/null \
        | jq -r '[.[] | select(.stable == true)][0:5][] | .version' 2>/dev/null)
    return 1
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
    if ! kokoro_go_download "$go_version" "$arch" "$tmp"; then
        go_version="$(kokoro_go_first_downloadable "$arch" "$tmp")" \
            || kokoro_die "failed to download Go ${KOKORO_GO_VERSION}"
        kokoro_warn "Go ${KOKORO_GO_VERSION} unavailable; falling back to ${go_version}"
        prefix="${KOKORO_GO_PREFIX}/go${go_version}"
        go_bin="${prefix}/bin/go"
    fi

    rm -rf "$prefix"
    install -d "$KOKORO_GO_PREFIX"
    tar -C "$KOKORO_GO_PREFIX" -xzf "${tmp}/go.tgz" || kokoro_die "failed to extract Go ${go_version}"
    mv "${KOKORO_GO_PREFIX}/go" "$prefix"
    rm -rf "$tmp"
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
    local dest caddy_version go_bin go_path
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
    export GOBIN=/usr/local/bin
    kokoro_run_cmd "install xcaddy" "$go_bin" install "github.com/caddyserver/xcaddy/cmd/xcaddy@${KOKORO_XCADDY_VERSION}" \
        || kokoro_die "failed to install xcaddy ${KOKORO_XCADDY_VERSION}"
    [[ -x /usr/local/bin/xcaddy ]] || kokoro_die "xcaddy not found after install"

    if kokoro_caddy_needs_l4; then
        kokoro_log "building Caddy ${caddy_version} with caddy-l4 ${KOKORO_CADDY_L4_VERSION}"
        kokoro_log "this can take several minutes on small VPS instances"
        kokoro_run_cmd "caddy build" /usr/local/bin/xcaddy build "$caddy_version" --with "github.com/mholt/caddy-l4@${KOKORO_CADDY_L4_VERSION}" --output "$dest" \
            || kokoro_die "failed to build Caddy ${caddy_version}"
    else
        kokoro_log "building Caddy ${caddy_version}"
        kokoro_log "this can take several minutes on small VPS instances"
        kokoro_run_cmd "caddy build" /usr/local/bin/xcaddy build "$caddy_version" --output "$dest" \
            || kokoro_die "failed to build Caddy ${caddy_version}"
    fi

    [[ -x "$dest" || -f "$dest" ]] || kokoro_die "caddy build did not create $dest"
    chmod 755 "$dest"
    if kokoro_caddy_needs_l4; then
        "$dest" list-modules 2>/dev/null | grep -q 'layer4' || kokoro_die "caddy-l4 module missing after xcaddy build"
    fi
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
