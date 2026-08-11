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

echo "caddy-tune-test OK"
