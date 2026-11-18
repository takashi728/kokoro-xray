#!/usr/bin/env bash
# PrivateBin is used only by the RAW TLS fallback, never by REALITY's target.

[[ -n "${KOKORO_FALLBACK_LOADED:-}" ]] && return 0
KOKORO_FALLBACK_LOADED=1

source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
source "${KOKORO_ROOT}/lib/os.sh"

# PrivateBin fs 2.1.1; immutable multi-architecture manifest, reviewed 2026-11-18.
readonly KOKORO_PRIVATEBIN_IMAGE='ghcr.io/privatebin/fs@sha256:9952bf85eb77c271aa04e3c2252cb1b4a9351acdfe32f053c3825ffb4aae80d8'
readonly KOKORO_PRIVATEBIN_CONFIG='/etc/kokoro-xray/privatebin.conf.php'

kokoro_fallback_unit_content() {
    cat <<EOF
[Unit]
Description=PrivateBin RAW TLS fallback (kokoro-xray)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm -f kokoro-fallback
ExecStart=/usr/bin/podman run --rm --name kokoro-fallback --pull=never --read-only --read-only-tmpfs=false --image-volume=ignore --user=65534:82 --cap-drop=all --security-opt=no-new-privileges --pids-limit=64 --memory=192m --memory-swap=192m --cpus=0.5 --publish=127.0.0.1:8081:8080 --tmpfs=/run:rw,nodev,nosuid,exec,mode=1777,size=8m --tmpfs=/tmp:rw,nodev,nosuid,noexec,mode=1777,size=8m --tmpfs=/srv/data:rw,nodev,nosuid,noexec,mode=1777,size=16m --tmpfs=/var/lib/nginx/tmp:rw,nodev,nosuid,noexec,mode=1777,size=8m --volume=${KOKORO_PRIVATEBIN_CONFIG}:/srv/cfg/conf.php:ro,Z ${KOKORO_PRIVATEBIN_IMAGE}
ExecStop=/usr/bin/podman stop --time=10 kokoro-fallback
ExecStopPost=-/usr/bin/podman rm -f kokoro-fallback
Restart=on-failure
RestartSec=3
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
}

kokoro_fallback_install() {
    kokoro_raw_tls_enabled || return 0
    kokoro_need_root
    [[ -x /usr/bin/podman ]] || kokoro_pkg_install podman
    if ! /usr/bin/podman image exists "$KOKORO_PRIVATEBIN_IMAGE"; then
        /usr/bin/podman pull "$KOKORO_PRIVATEBIN_IMAGE" || kokoro_die "failed to pull pinned PrivateBin image"
    fi
    install -d -m 755 /etc/kokoro-xray
    install -m 644 "${KOKORO_ROOT}/templates/privatebin/conf.php" "$KOKORO_PRIVATEBIN_CONFIG"
    kokoro_install_systemd_unit kokoro-fallback.service "$(kokoro_fallback_unit_content)"
    systemctl daemon-reload
    if systemctl is-active --quiet kokoro-fallback.service; then
        systemctl restart kokoro-fallback.service || kokoro_die "failed to restart updated fallback"
    fi
}

kokoro_fallback_preflight() {
    kokoro_raw_tls_enabled || return 0
    [[ -f "$KOKORO_PRIVATEBIN_CONFIG" ]] &&
        [[ -f "$(kokoro_systemd_unit_dir)/kokoro-fallback.service" ]] &&
        [[ -x /usr/bin/podman ]] && /usr/bin/podman image exists "$KOKORO_PRIVATEBIN_IMAGE" ||
        kokoro_die "RAW TLS fallback is not installed; run kokoro-xray edge"
}

kokoro_fallback_sync() {
    if kokoro_raw_tls_enabled; then
        systemctl enable --now kokoro-fallback.service || return 1
        local i
        for i in $(seq 1 20); do
            if curl -fsS --max-time 2 http://127.0.0.1:8081/ >/dev/null; then return 0; fi
            sleep 1
        done
        kokoro_die "PrivateBin fallback did not become ready; check kokoro-fallback.service"
    elif [[ -f "$(kokoro_systemd_unit_dir)/kokoro-fallback.service" ]]; then
        systemctl disable --now kokoro-fallback.service || return 1
    fi
}
