#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

state="${TMP}/.kokoro-xray"
unit_dir="${TMP}/units"
install -d -m 700 "$state" "$unit_dir"

jq --arg cert "${TMP}/cert.pem" --arg key "${TMP}/key.pem" '
  .role = "edge"
  | .inbound.mode = "both"
  | .inbound.tls.cdn_domain = "edge.example.com"
  | .inbound.hysteria.enabled = true
  | .inbound.hysteria.domain = "hy.example.com"
  | .inbound.hysteria.acme_email = "admin@example.com"
  | .paths.hysteria_cert = $cert
  | .paths.hysteria_key = $key
' "$ROOT/config.defaults.json" >"${state}/config.json"
cp "$ROOT/secrets.defaults.json" "${state}/secrets.json"
touch "${TMP}/cert.pem" "${TMP}/key.pem"

HOME="$TMP" KOKORO_ROOT="$ROOT" KOKORO_SYSTEMD_UNIT_DIR="$unit_dir" bash -c '
  set -euo pipefail
  source "${KOKORO_ROOT}/lib/reload.sh"
  systemctl() {
      printf "%s\n" "$*" >>"${HOME}/systemctl.log"
  }
  kokoro_hysteria_cert_reload_sync
'

path_unit="${unit_dir}/kokoro-hysteria-cert.path"
service_unit="${unit_dir}/kokoro-hysteria-cert-reload.service"
[[ -f "$path_unit" && -f "$service_unit" ]]
[[ "$(stat -c '%a' "$path_unit")" == "644" ]]
[[ "$(stat -c '%a' "$service_unit")" == "644" ]]
grep -qx "PathChanged=${TMP}/cert.pem" "$path_unit"
grep -qx "PathChanged=${TMP}/key.pem" "$path_unit"
grep -qx 'Unit=kokoro-hysteria-cert-reload.service' "$path_unit"
grep -qx 'ExecStart=/usr/bin/systemctl restart xray.service' "$service_unit"
grep -qx 'enable --now kokoro-hysteria-cert.path' "${TMP}/systemctl.log"

HOME="$TMP" KOKORO_ROOT="$ROOT" KOKORO_SYSTEMD_UNIT_DIR="$unit_dir" bash -c '
  set -euo pipefail
  source "${KOKORO_ROOT}/lib/reload.sh"
  kokoro_cfg() {
      if [[ "$1" == ".inbound.hysteria.enabled // false" ]]; then
          printf "false"
      else
          jq -r "$1" "${KOKORO_CONFIG}"
      fi
  }
  systemctl() {
      printf "%s\n" "$*" >>"${HOME}/systemctl.log"
  }
  kokoro_hysteria_cert_reload_sync
'
[[ ! -e "$path_unit" && ! -e "$service_unit" ]]
grep -qx 'disable kokoro-hysteria-cert.path' "${TMP}/systemctl.log"

echo "reload-test OK"
