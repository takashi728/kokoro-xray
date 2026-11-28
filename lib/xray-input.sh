#!/usr/bin/env bash
set -euo pipefail

prepare_input() (
    local config="$1" cert_root="$2" work indexes index field suffix path
    local -a reader=()
    if (( EUID == 0 )); then reader=(runuser -u kokoro-caddy --); fi
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    cp -- "$config" "$work/input"
    indexes="$(jq -r '.inbounds | to_entries[] | select(
        .value.streamSettings.tlsSettings.certificates != null) | .key' "$work/input")"
    for index in $indexes; do
        for field in certificateFile keyFile; do
            if [[ "$field" == certificateFile ]]; then suffix=crt; else suffix=key; fi
            path="$(jq -er --argjson index "$index" --arg field "$field" \
                '.inbounds[$index].streamSettings.tlsSettings.certificates |
                 select(length == 1) | .[0][$field] | strings |
                 select(test("\\A/[A-Za-z0-9._/+@:-]+\\z"))' "$work/input")"
            [[ "$path" == "$cert_root/"*."$suffix" && -f "$path" && "$(realpath -e -- "$path")" == "$path" ]] ||
                { echo 'Invalid managed Xray certificate path' >&2; exit 1; }
            "${reader[@]}" cat -- "$path" >"$work/$field"
        done
        jq --argjson index "$index" --rawfile cert "$work/certificateFile" --rawfile key "$work/keyFile" '
            .inbounds[$index].streamSettings.tlsSettings.certificates[0] |=
            (del(.certificateFile, .keyFile) + {certificate: ($cert | split("\n") | map(select(length > 0))),
                                                  key: ($key | split("\n") | map(select(length > 0)))})' \
            "$work/input" >"$work/next"
        mv -- "$work/next" "$work/input"
    done
    cat -- "$work/input"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    config=/usr/local/etc/xray/config.json
    cert_root=/var/lib/kokoro-caddy/certificates
    case "${1:-}" in
        --stdout) prepare_input "$config" "$cert_root" ;;
        --stage)
            run_dir=/run/kokoro-xray-input
            install -d -m 0750 -o root -g kokoro-xray "$run_dir"
            staged="$(mktemp -- "$run_dir/config.XXXXXX")"
            trap 'rm -f -- "$staged"' EXIT
            prepare_input "$config" "$cert_root" >"$staged"
            chgrp kokoro-xray "$staged"
            chmod 0440 "$staged"
            mv -fT -- "$staged" "$run_dir/config.json"
            ;;
        *) exit 2 ;;
    esac
fi
