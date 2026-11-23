#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${ROOT}/lib/caddy.sh"

# pure tuning: single-core low-RAM Intel box
[[ "$(kokoro_build_tuning 1 1024)" == $'GOFLAGS=-p=1\nGOGC=25\nGOMEMLIMIT=768MiB' ]]
[[ "$(kokoro_build_tuning 1 2048)" == $'GOFLAGS=-p=1\nGOGC=25\nGOMEMLIMIT=1536MiB' ]]
[[ "$(kokoro_build_tuning 2 3072)" == $'GOFLAGS=-p=1\nGOGC=25\nGOMEMLIMIT=2304MiB' ]]
kokoro_build_tuning 2 4096 | grep -q 'GOMEMLIMIT=3072MiB'

# fast multi-core box: no memory limits, no -p=1
[[ "$(kokoro_build_tuning 8 16384)" == "GOFLAGS=" ]]

# runner seam: KOKORO_RUNNER receives label + command
calls=()
kokoro_fake_runner() {
    calls+=("$1")
    shift
    [[ "$1" == "xcaddy" ]]
}
KOKORO_RUNNER=kokoro_fake_runner
kokoro_run_cmd "caddy build" xcaddy build v2 --output /tmp/x
[[ "${calls[0]}" == "caddy build" ]]

# Small hosts top up active swap and take the download path instead of building.
nproc() { printf '%s\n' "$test_cpus"; }
kokoro_ram_kib() { printf '%s\n' "$test_ram"; }
test_cpus=2 test_ram=4194304
kokoro_small_vps
test_cpus=3
! kokoro_small_vps || exit 1
test_cpus=2 test_ram=4194305
! kokoro_small_vps || exit 1
[[ "$(kokoro_swap_needed_kib 4194304 1048576)" == 3145728 ]]
[[ "$(kokoro_swap_needed_kib 4194304 5242880)" == 0 ]]

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
test_ram=4194304
kokoro_cfg() { printf '%s\n' "$tmp/caddy"; }
kokoro_caddy_version() { printf '%s\n' v2.11.9; }
kokoro_need_root() { :; }
kokoro_validate_service_paths() { :; }
kokoro_caddy_install_service() { :; }
kokoro_caddy_needs_l4() { return 0; }
kokoro_caddy_download() {
    [[ "$1" == v2.11.9 ]] || return 1
    printf '#!/bin/sh\ncase "$1" in version) echo v2.11.9;; list-modules) echo layer4;; esac\n' >"$2"
}
kokoro_caddy_build() { return 1; }
kokoro_caddy_install
[[ "$("$tmp/caddy" version)" == v2.11.9 ]]

echo "caddy-tune-test OK"
