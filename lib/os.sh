#!/usr/bin/env bash
# kokoro-xray — OS detection and package helpers

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

kokoro_detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        KOKORO_OS_ID="${ID:-unknown}"
        KOKORO_OS_VER="${VERSION_ID:-}"
    else
        KOKORO_OS_ID="unknown"
        KOKORO_OS_VER=""
    fi
}

kokoro_os_supported() {
    kokoro_detect_os
    case "${KOKORO_OS_ID}" in
        debian | ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

kokoro_ram_kib() { awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo; }

kokoro_small_vps() {
    local cpus ram
    cpus="$(nproc)" || return 1
    ram="$(kokoro_ram_kib)" || return 1
    [[ "$cpus" =~ ^[1-9][0-9]*$ && "$ram" =~ ^[1-9][0-9]*$ ]] &&
        (( cpus <= 2 && ram <= 4 * 1024 * 1024 ))
}

kokoro_swap_needed_kib() { # RAM and active swap, both in KiB
    local missing=$(( $1 - $2 ))
    printf '%s\n' "$(( missing > 0 ? missing : 0 ))"
}

kokoro_small_vps_swap() (
    kokoro_small_vps || return 0
    kokoro_need_root
    local swapfile=/var/lib/kokoro-swapfile ram active needed available staged
    exec 9>/run/lock/kokoro-swap.lock
    flock -x 9 || return 1
    ram="$(kokoro_ram_kib)" || return 1
    if [[ -e "$swapfile" || -L "$swapfile" ]]; then
        [[ -f "$swapfile" && ! -L "$swapfile" && "$(stat -c '%u:%a' "$swapfile")" == "0:600" ]] ||
            kokoro_die "unsafe existing swap file: $swapfile"
        if ! awk -v path="$swapfile" '$1 == path {found=1} END {exit !found}' /proc/swaps; then
            swapon "$swapfile" || kokoro_die "could not enable $swapfile"
        fi
    else
        active="$(awk 'NR > 1 {sum += $3} END {printf "%.0f\n", sum}' /proc/swaps)" || return 1
        needed="$(kokoro_swap_needed_kib "$ram" "$active")"
        (( needed > 0 )) || return 0
        available="$(df -Pk /var/lib | awk 'NR == 2 {print $4}')" || return 1
        (( available >= needed + 256 * 1024 )) ||
            kokoro_die "not enough free space for RAM-sized swap; enable swap or zram first"
        staged="$(mktemp "${swapfile}.XXXXXX")" || return 1
        trap 'rm -f -- "$staged"' EXIT
        # Round up to leave space for the swap header.
        local mib=$(( (needed + 1024) / 1024 + 1 ))
        if [[ "$(findmnt -n -o FSTYPE -T /var/lib)" == btrfs ]]; then
            command -v btrfs >/dev/null || kokoro_die "install btrfs-progs or enable zram first"
            rm -- "$staged" && btrfs filesystem mkswapfile --size "${mib}m" "$staged" ||
                kokoro_die "could not create Btrfs swap"
            chmod 600 "$staged" || return 1
        else
            dd if=/dev/zero of="$staged" bs=1M count="$mib" status=none &&
                mkswap "$staged" >/dev/null || kokoro_die "could not create disk swap"
        fi
        mv -T -- "$staged" "$swapfile" || return 1
        if ! swapon "$swapfile"; then
            rm -f -- "$swapfile"
            kokoro_die "kernel refused swap; enable swap or zram through your VPS provider"
        fi
    fi
    if ! awk -v path="$swapfile" '$1 == path && $3 == "swap" {found=1} END {exit !found}' /etc/fstab; then
        printf '\n%s none swap sw,nofail 0 0\n' "$swapfile" >> /etc/fstab || return 1
        systemctl daemon-reload || return 1
    fi
    active="$(awk 'NR > 1 {sum += $3} END {printf "%.0f\n", sum}' /proc/swaps)" || return 1
    (( active >= ram )) || kokoro_die "active swap remains below RAM size; add more swap or zram"
    kokoro_log "disk swap active and persistent: $swapfile"
)

kokoro_pkg_install() {
    kokoro_detect_os
    kokoro_need_root
    case "${KOKORO_OS_ID}" in
        debian | ubuntu)
            apt-get -o DPkg::Lock::Timeout=120 update -qq
            DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
                apt-get -o DPkg::Lock::Timeout=120 install -y -qq "$@"
            ;;
        *)
            kokoro_die "unsupported OS: ${KOKORO_OS_ID}"
            ;;
    esac
}

kokoro_install_deps() {
    local package
    local -a packages=(
        ca-certificates curl git jq openssl tar unzip
        uuid-runtime wireguard-tools ufw libc-bin procps iproute2
    )
    local -a missing=()

    kokoro_os_supported || kokoro_die "only Debian/Ubuntu supported for now"
    for package in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
            grep -q 'ok installed' || missing+=("$package")
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        kokoro_log "dependencies already installed"
        return 0
    fi

    kokoro_log "installing dependencies: ${missing[*]}"
    kokoro_pkg_install "${missing[@]}"
}
