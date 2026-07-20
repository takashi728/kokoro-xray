#!/usr/bin/env bash
# kokoro-xray — REALITY target scanner (requirement-based validation)

: "${KOKORO_ROOT:=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${KOKORO_ROOT}/lib/common.sh"

KOKORO_REALITY_SCAN_TIMEOUT="${KOKORO_REALITY_SCAN_TIMEOUT:-8}"

kokoro_reality_blocked() {
    local host="${1,,}"
    [[ "$host" == *apple* ||
        "$host" == *icloud* ||
        "$host" == *microsoft* ||
        "$host" == *.cn ||
        "$host" == *.ru ||
        "$host" == *.ir ]]
}

kokoro_reality_normalize_host() {
    local h="$1"
    h="${h#https://}"
    h="${h#http://}"
    h="${h%%/*}"
    h="${h%%:*}"
    printf '%s\n' "$h"
}

kokoro_reality_cert_covers_host() {
    local host="$1" san base wildcard
    san="$(timeout "${KOKORO_REALITY_SCAN_TIMEOUT}" openssl s_client \
        -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
    [[ -n "$san" ]] || return 1
    if [[ "$san" == *"DNS:${host}"* ]]; then
        return 0
    fi
    base="${host#*.}"
    if [[ "$host" == *.* && "$san" == *"DNS:*.${base}"* ]]; then
        return 0
    fi
    wildcard="*.${base}"
    [[ "$san" == *"DNS:${wildcard}"* ]] && return 0
    return 1
}

kokoro_reality_bad_redirect() {
    local host="$1" code loc lh
    code="$(timeout 5 curl -sI --max-redirs 0 "https://${host}/" 2>/dev/null \
        | awk 'toupper($1)=="HTTP/" {print $2; exit}')"
    loc="$(timeout 5 curl -sI --max-redirs 0 "https://${host}/" 2>/dev/null \
        | awk 'tolower($1)=="location:" {print $2; exit}' | tr -d '\r')"
    [[ "$code" =~ ^30[1278]$ ]] || return 1
    [[ -n "$loc" ]] || return 1
    lh="$(kokoro_reality_normalize_host "$loc")"
    # REALITY README: apex → www-only redirect is bad
    if [[ "$host" != www.* && "$lh" == "www.${host}" ]]; then
        return 0
    fi
    return 1
}

kokoro_reality_has_ocsp() {
    local host="$1"
    timeout "${KOKORO_REALITY_SCAN_TIMEOUT}" openssl s_client \
        -connect "${host}:443" -servername "$host" -status </dev/null 2>&1 \
        | grep -q 'OCSP Response Status: successful'
}

kokoro_reality_validate_one() {
    local host="$1"
    local latency=0 score=0 tags="" log
    log="$(mktemp)"

    host="$(kokoro_reality_normalize_host "$host")"
    if [[ -z "$host" ]]; then
        echo -e "FAIL\t0\t0\tempty"
        return
    fi

    if kokoro_reality_blocked "$host"; then
        echo -e "FAIL\t0\t0\tupstream-risk-blocked\t${host}"
        return
    fi

    if ! getent ahosts "$host" >/dev/null 2>&1; then
        echo -e "FAIL\t0\t0\tdns-fail\t${host}"
        return
    fi

    local t0 t1
    t0="$(( $(date +%s%N) / 1000000 ))"
    if ! timeout "${KOKORO_REALITY_SCAN_TIMEOUT}" openssl s_client \
        -connect "${host}:443" -servername "$host" -alpn h2 -tls1_3 \
        </dev/null >"$log" 2>&1; then
        echo -e "FAIL\t0\t0\tconnect-fail\t${host}"
        rm -f "$log"
        return
    fi
    t1="$(( $(date +%s%N) / 1000000 ))"
    latency="$(( t1 - t0 ))"

    if ! grep -qE 'Protocol version: TLSv1.3|^Protocol: TLSv1.3' "$log"; then
        echo -e "FAIL\t${latency}\t0\tno-tls1.3\t${host}"
        rm -f "$log"
        return
    fi
    if ! grep -q 'ALPN protocol: h2' "$log"; then
        echo -e "FAIL\t${latency}\t0\tno-alpn-h2\t${host}"
        rm -f "$log"
        return
    fi
    rm -f "$log"
    tags="tls1.3,h2"
    score=40

    if kokoro_reality_cert_covers_host "$host"; then
        tags+=",san-ok"
        score=$(( score + 25 ))
    else
        echo -e "FAIL\t${latency}\t0\tsan-mismatch\t${host}"
        return
    fi

    if kokoro_reality_bad_redirect "$host"; then
        echo -e "FAIL\t${latency}\t0\tapex-redirect\t${host}"
        return
    fi
    tags+=",no-bad-redirect"
    score=$(( score + 20 ))

    if kokoro_reality_has_ocsp "$host"; then
        tags+=",ocsp"
        score=$(( score + 10 ))
    fi

    if [[ "$latency" -lt 200 ]]; then score=$(( score + 5 ))
    elif [[ "$latency" -lt 500 ]]; then score=$(( score + 3 ))
    elif [[ "$latency" -lt 1000 ]]; then score=$(( score + 1 ))
    fi

    echo -e "OK\t${score}\t${latency}\t${tags}\t${host}"
}

kokoro_reality_collect_hosts() {
    local seeds="${KOKORO_ROOT}/data/reality-seeds.txt"
    local file_arg="" domain_arg=""
    local -a extra=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) file_arg="$2"; shift 2 ;;
            --domains) domain_arg="$2"; shift 2 ;;
            *) extra+=("$1"); shift ;;
        esac
    done

    if [[ -f "$seeds" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            kokoro_reality_normalize_host "$line"
        done <"$seeds"
    fi

    if [[ -n "$file_arg" && -f "$file_arg" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            kokoro_reality_normalize_host "$line"
        done <"$file_arg"
    fi

    if [[ -n "$domain_arg" ]]; then
        local IFS=',' d
        for d in $domain_arg; do
            d="$(echo "$d" | xargs)"
            [[ -n "$d" ]] && kokoro_reality_normalize_host "$d"
        done
    fi

    for line in "${extra[@]}"; do
        [[ -n "$line" ]] && kokoro_reality_normalize_host "$line"
    done
}

kokoro_reality_apply_host() {
    local host="$1"
    host="$(kokoro_reality_normalize_host "$host")"
    [[ -n "$host" ]] || kokoro_die "empty REALITY host"
    kokoro_ensure_state
    kokoro_cfg_set_str '.inbound.reality.dest' "${host}:443"
    kokoro_cfg_set '.inbound.reality.server_names' "[\"${host}\"]"
    kokoro_log "REALITY target: ${host}"
}

kokoro_reality_scan_pick() {
    local tmp_ranked="$1" limit="$2" select="$3"
    local n shown choice row host score

    n="$(grep -c '^OK' "$tmp_ranked" 2>/dev/null || echo 0)"
    [[ "$n" -gt 0 ]] || return 1
    shown="$n"
    [[ "$shown" -gt "$limit" ]] && shown="$limit"

    if [[ "$select" == "true" && -t 0 ]]; then
        echo ""
        printf '%s\n' "#  host                             score latency tags"
        awk -F'\t' -v lim="$shown" '
            NR <= lim { printf " %d  %-32s %5s %5sms %s\n", NR, $5, $2, $3, $4 }
        ' <(grep '^OK' "$tmp_ranked" | sort -t$'\t' -k2 -nr | head -n "$shown")
        echo ""
        while true; do
            read -r -p "Choice [1-${shown}] (1=best): " choice
            choice="${choice:-1}"
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "$shown" ]]; then
                row="$(grep '^OK' "$tmp_ranked" | sort -t$'\t' -k2 -nr | sed -n "${choice}p")"
                [[ -n "$row" ]] && break
            fi
            kokoro_warn "enter a number between 1 and ${shown}"
        done
        host="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
        score="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
        kokoro_reality_apply_host "$host"
        kokoro_log "selected #${choice}: ${host} (score=${score})"
        return 0
    fi

    row="$(grep '^OK' "$tmp_ranked" | sort -t$'\t' -k2 -nr | head -1)"
    host="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
    score="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
    kokoro_reality_apply_host "$host"
    kokoro_log "best: ${host} (score=${score})"
    return 0
}

kokoro_reality_scan() {
    local limit=15 apply=false select=false jobs=6
    local -a collect_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit) limit="$2"; shift 2 ;;
            --apply) apply=true; shift ;;
            --select) select=true; shift ;;
            --jobs) jobs="$2"; shift 2 ;;
            --file|--domains) collect_args+=("$1" "$2"); shift 2 ;;
            -h|--help)
                cat <<'EOF'
kokoro-xray reality scan — validate REALITY targets

Checks each hostname (no bulk third-party import):
  DNS resolve, TLS 1.3, ALPN h2, cert SAN, redirect rules.
Rejects Apple/iCloud/Microsoft names and .cn/.ru/.ir TLDs per Xray-core.

Usage:
  kokoro-xray reality scan
  kokoro-xray reality scan --domains www.sky.com,github.com
  kokoro-xray reality scan --file extra-hosts.txt --limit 10
  kokoro-xray reality scan --apply
  kokoro-xray reality scan --select

Options:
  --limit N     Show top N (default 15)
  --jobs N      Parallel probes (default 6)
  --apply       Set best result in config.json
  --select      Interactive menu — pick from ranked results
  --domains     Comma-separated hosts to probe
  --file        Extra hosts file (one per line)
EOF
                return 0
                ;;
            *) collect_args+=("$1"); shift ;;
        esac
    done

    if [[ "$apply" == "true" && "$select" == "true" ]]; then
        kokoro_die "use --apply or --select, not both"
    fi

    kokoro_need_cmd openssl
    kokoro_need_cmd curl
    kokoro_need_cmd getent

    local tmp_hosts tmp_out
    tmp_hosts="$(mktemp)"
    tmp_out="$(mktemp)"
    kokoro_reality_collect_hosts "${collect_args[@]}" | sort -u | grep -v '^$' >"$tmp_hosts"

    local count
    count="$(wc -l <"$tmp_hosts" | tr -d ' ')"
    [[ "$count" -gt 0 ]] || kokoro_die "no hosts to scan"

    kokoro_log "scanning ${count} host(s) (REALITY requirement validation)..."

    export KOKORO_ROOT KOKORO_REALITY_SCAN_TIMEOUT

    while IFS= read -r h; do
        while [[ "$(jobs -rp | wc -l)" -ge "$jobs" ]]; do
            sleep 0.1
        done
        bash "${KOKORO_ROOT}/lib/reality-scan.sh" probe "$h" >>"$tmp_out" 2>/dev/null &
    done <"$tmp_hosts"
    wait

    echo ""
    printf '%s\n' "host                             score latency tags"
    grep '^OK' "$tmp_out" | sort -t$'\t' -k2 -nr | head -n "$limit" \
        | awk -F'\t' '{printf "%-32s %5s %5sms %s\n", $5, $2, $3, $4}'

    local fail_n ok_n
    fail_n="$(grep -c '^FAIL' "$tmp_out" 2>/dev/null || echo 0)"
    ok_n="$(grep -c '^OK' "$tmp_out" 2>/dev/null || echo 0)"
    echo ""
    kokoro_log "passed: ${ok_n}  failed: ${fail_n}"

    if [[ "$ok_n" -eq 0 ]]; then
        echo -e "${YELLOW}sample failures:${NC}"
        grep '^FAIL' "$tmp_out" | head -10 \
            | awk -F'\t' '{printf "  %-32s %s\n", $5, $4}'
        rm -f "$tmp_hosts" "$tmp_out"
        return 1
    fi

    if [[ "$apply" == "true" || "$select" == "true" ]]; then
        if kokoro_reality_scan_pick "$tmp_out" "$limit" "$select"; then
            kokoro_log "config updated — run: kokoro-xray apply"
        else
            rm -f "$tmp_hosts" "$tmp_out"
            return 1
        fi
    else
        local best best_host best_score
        best="$(grep '^OK' "$tmp_out" | sort -t$'\t' -k2 -nr | head -1)"
        best_host="$(printf '%s' "$best" | awk -F'\t' '{print $5}')"
        best_score="$(printf '%s' "$best" | awk -F'\t' '{print $2}')"
        echo ""
        kokoro_log "best: ${best_host} (score=${best_score})"
    fi

    rm -f "$tmp_hosts" "$tmp_out"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    export KOKORO_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
    case "${1:-}" in
        probe) kokoro_reality_validate_one "${2:-}" ;;
        *) kokoro_reality_scan "$@" ;;
    esac
fi
