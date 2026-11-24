#!/usr/bin/env bash
# kokoro-xray — bootstrap installer

set -euo pipefail

REPO_URL="${KOKORO_REPO_URL:-https://github.com/takashi728/kokoro-xray}"
REPO_COMMIT="${KOKORO_REPO_COMMIT:-}"
INSTALL_DIR="${KOKORO_INSTALL_DIR:-/opt/kokoro-xray}"
INSTALL_SOURCE="${KOKORO_INSTALL_SOURCE:-auto}"
CLEAN_INSTALL=false
INSTALL_ARGS=()

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

RED='\033[31m'; GREEN='\033[32m'; CYAN='\033[36m'; NC='\033[0m'

die() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
log() { echo -e "${GREEN}[kokoro]${NC} $*"; }

print_banner() {
    printf '%b' "${CYAN}"
    cat <<'EOF'
    __         __
   / /______  / /______  _________        _  ___________ ___  __
  / //_/ __ \/ //_/ __ \/ ___/ __ \______| |/_/ ___/ __ `/ / / /
 / ,< / /_/ / ,< / /_/ / /  / /_/ /_____/>  </ /  / /_/ / /_/ /
/_/|_|\____/_/|_|\____/_/   \____/     /_/|_/_/   \__,_/\__, /
                                                       /____/

  ( kokoro 心 — with heart, at full speed )
EOF
    printf '%b\n' "${NC}"
}

print_banner

[[ "${EUID}" -eq 0 ]] || die "run as root"

SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-install)
            CLEAN_INSTALL=true
            shift
            ;;
        --commit)
            [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] || die "--commit requires a full 40-character SHA"
            REPO_COMMIT="$2"
            shift 2
            ;;
        --local)
            INSTALL_SOURCE=local
            shift
            ;;
        --remote)
            INSTALL_SOURCE=remote
            shift
            ;;
        *)
            INSTALL_ARGS+=("$1")
            shift
            ;;
    esac
done

[[ "$INSTALL_SOURCE" == "auto" || "$INSTALL_SOURCE" == "local" || "$INSTALL_SOURCE" == "remote" ]] ||
    die "KOKORO_INSTALL_SOURCE must be auto, local, or remote"

safe_install_dir() {
    [[ -n "$INSTALL_DIR" ]] || die "KOKORO_INSTALL_DIR is empty"
    [[ "$INSTALL_DIR" == /* ]] || die "KOKORO_INSTALL_DIR must be absolute: $INSTALL_DIR"

    case "$INSTALL_DIR" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/usr/local|/var)
            die "refusing unsafe install dir: $INSTALL_DIR"
            ;;
    esac

    if [[ -L "$INSTALL_DIR" ]]; then
        die "refusing symlink install dir: $INSTALL_DIR"
    fi
}

install_bootstrap_deps() {
    local package
    local -a packages=(
        ca-certificates curl git jq openssl tar unzip
        uuid-runtime wireguard-tools ufw libc-bin procps iproute2
    )
    local -a missing=()

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            debian | ubuntu)
                for package in "${packages[@]}"; do
                    dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
                        grep -q 'ok installed' || missing+=("$package")
                done
                if [[ "${#missing[@]}" -eq 0 ]]; then
                    log "dependencies already installed"
                    return 0
                fi

                log "updating package index"
                apt-get -o DPkg::Lock::Timeout=120 update -qq ||
                    die "failed to update package index"
                log "installing dependencies: ${missing[*]}"
                DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
                    apt-get -o DPkg::Lock::Timeout=120 install -y -qq "${missing[@]}" ||
                    die "failed to install required packages"
                ;;
            *)
                die "unsupported OS: ${ID:-unknown} (Debian or Ubuntu required)"
                ;;
        esac
    else
        die "cannot detect operating system"
    fi
}

install_local() {
    local src="$SCRIPT_DIR" staged="${INSTALL_DIR}.new.$$" old="${INSTALL_DIR}.old.$$"
    local source_commit="" recorded_commit=""
    [[ -f "${src}/kokoro-xray.sh" ]] || die "run from repo root or set KOKORO_REPO_URL"
    if [[ -d "${src}/.git" ]]; then
        source_commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
        [[ -z "$(git -C "$src" status --porcelain --untracked-files=no 2>/dev/null)" ]] ||
            die "local checkout has uncommitted tracked changes"
    elif [[ -f "${src}/.kokoro-install-commit" ]]; then
        source_commit="$(tr -d '[:space:]' <"${src}/.kokoro-install-commit")"
    fi
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] ||
        die "local tree has no verifiable Git revision"
    [[ -n "$REPO_COMMIT" ]] || REPO_COMMIT="$source_commit"
    [[ "$source_commit" == "$REPO_COMMIT" ]] ||
        die "local checkout ${source_commit} does not match reviewed commit ${REPO_COMMIT}"
    if [[ -f "${src}/.kokoro-install-commit" ]]; then
        recorded_commit="$(tr -d '[:space:]' <"${src}/.kokoro-install-commit")"
        [[ "$recorded_commit" == "$source_commit" ]] ||
            die "recorded local revision ${recorded_commit:-unset} does not match checkout ${source_commit}"
    fi
    safe_install_dir
    if [[ "$CLEAN_INSTALL" == "true" ]] &&
        [[ "$(realpath -m -- "$src")" == "$(realpath -m -- "$INSTALL_DIR")" ]]; then
        die "clean reinstall from the live install dir requires --remote"
    fi
    rm -rf -- "$staged"
    install -d "$staged"
    cp -a "${src}/." "$staged/"
    printf '%s\n' "$source_commit" >"${staged}/.kokoro-install-commit"
    chmod 644 "${staged}/.kokoro-install-commit"
    if [[ -e "$INSTALL_DIR" ]]; then
        rm -rf -- "$old"
        mv "$INSTALL_DIR" "$old"
    fi
    if ! mv "$staged" "$INSTALL_DIR"; then
        [[ -e "$old" ]] && mv "$old" "$INSTALL_DIR"
        rm -rf -- "$staged"
        die "failed to activate local repository"
    fi
    rm -rf -- "$old"
    chmod +x "${INSTALL_DIR}/kokoro-xray.sh" "${INSTALL_DIR}/install.sh"
    chmod +x "${INSTALL_DIR}/lib/"*.sh "${INSTALL_DIR}/roles/"*.sh 2>/dev/null || true
    chmod 644 "${INSTALL_DIR}/data/"*.txt 2>/dev/null || true
}

mark_installed_commit() { # commit
    local commit="$1" state_dir="${HOME}/.kokoro-xray"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "cannot record invalid installed commit"
    install -d -m 700 "$state_dir"
    printf '%s\n' "$commit" >"${state_dir}/installed-commit"
    chmod 644 "${state_dir}/installed-commit"
}

install_remote() {
    local staged="${INSTALL_DIR}.new.$$" old="${INSTALL_DIR}.old.$$" head
    [[ -n "$REPO_COMMIT" ]] ||
        die "remote install requires --commit or KOKORO_REPO_COMMIT"
    safe_install_dir
    rm -rf -- "$staged"
    git init -q "$staged" || { rm -rf -- "$staged"; die "failed to initialize staging repository"; }
    git -C "$staged" remote add origin "$REPO_URL" ||
        { rm -rf -- "$staged"; die "failed to configure repository origin"; }
    git -C "$staged" fetch --depth 1 origin "$REPO_COMMIT" ||
        { rm -rf -- "$staged"; die "failed to fetch reviewed commit ${REPO_COMMIT}"; }
    git -C "$staged" checkout --detach --force FETCH_HEAD ||
        { rm -rf -- "$staged"; die "failed to check out reviewed commit ${REPO_COMMIT}"; }
    head="$(git -C "$staged" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$head" != "$REPO_COMMIT" ]]; then
        rm -rf -- "$staged"
        die "cloned commit ${head:-unknown} does not match reviewed commit ${REPO_COMMIT}"
    fi
    printf '%s\n' "$REPO_COMMIT" >"${staged}/.kokoro-install-commit"
    chmod 644 "${staged}/.kokoro-install-commit"
    if [[ -e "$INSTALL_DIR" ]]; then
        rm -rf -- "$old"
        mv "$INSTALL_DIR" "$old"
    fi
    if ! mv "$staged" "$INSTALL_DIR"; then
        [[ -e "$old" ]] && mv "$old" "$INSTALL_DIR"
        rm -rf -- "$staged"
        die "failed to activate cloned repository"
    fi
    rm -rf -- "$old"
    chmod +x "${INSTALL_DIR}/kokoro-xray.sh" "${INSTALL_DIR}/install.sh"
    chmod +x "${INSTALL_DIR}/lib/"*.sh "${INSTALL_DIR}/roles/"*.sh 2>/dev/null || true
    chmod 644 "${INSTALL_DIR}/data/"*.txt 2>/dev/null || true
}

install_bootstrap_deps

has_local_tree=false
if [[ -f "${SCRIPT_DIR}/kokoro-xray.sh" ]]; then
    has_local_tree=true
fi

if [[ "$INSTALL_SOURCE" == "auto" ]]; then
    if [[ "$CLEAN_INSTALL" == "true" || "$has_local_tree" != "true" ]]; then
        INSTALL_SOURCE=remote
    else
        INSTALL_SOURCE=local
    fi
fi

if [[ "$INSTALL_SOURCE" == "local" && "$has_local_tree" != "true" ]]; then
    die "local install source requested but no repository checkout was found"
fi

if [[ "$INSTALL_SOURCE" == "remote" ]]; then
    install_remote
else
    install_local
fi

ln -sf "${INSTALL_DIR}/kokoro-xray.sh" /usr/local/bin/kokoro-xray

install -d -m 700 "${HOME}/.kokoro-xray"
mark_installed_commit "$REPO_COMMIT"
if [[ ! -f "${HOME}/.kokoro-xray/config.json" ]]; then
    cp "${INSTALL_DIR}/config.defaults.json" "${HOME}/.kokoro-xray/config.json"
    chmod 644 "${HOME}/.kokoro-xray/config.json"
fi
if [[ ! -f "${HOME}/.kokoro-xray/secrets.json" ]]; then
    cp "${INSTALL_DIR}/secrets.defaults.json" "${HOME}/.kokoro-xray/secrets.json"
    chmod 600 "${HOME}/.kokoro-xray/secrets.json"
fi

log "installed to ${INSTALL_DIR}"
log "run: kokoro-xray"

run_installed() {
    local tty_fd=false
    if [[ ! -t 0 ]] && { exec 3</dev/tty; } 2>/dev/null; then
        tty_fd=true
    fi
    if [[ "$tty_fd" == "true" ]]; then
        exec "$@" <&3 3<&-
    fi
    exec "$@"
}

case "${INSTALL_ARGS[0]:-}" in
    --edge) run_installed "${INSTALL_DIR}/kokoro-xray.sh" edge "${INSTALL_ARGS[@]:1}" ;;
    --exit) run_installed "${INSTALL_DIR}/kokoro-xray.sh" exit "${INSTALL_ARGS[@]:1}" ;;
    *) run_installed "${INSTALL_DIR}/kokoro-xray.sh" "${INSTALL_ARGS[@]}" ;;
esac
