#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

for lib in apply caddy cf fallback geodata health hysteria-hop keys os preflight reality-asn reality-cdn reality-scan reload render snapshot tor validate vless-encryption xray; do
    bash -c "source '${ROOT}/lib/${lib}.sh'" "${ROOT}/roles/edge.sh"
done

echo "source-path-test OK"
