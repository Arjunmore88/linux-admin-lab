#!/usr/bin/env bash
#
# health-check.sh - disk, memory, load and service health with
# Nagios-compatible exit codes, for systemd timers, cron or NRPE.
#
#   0 OK   1 WARNING   2 CRITICAL   3 UNKNOWN
#
# First line of output is a one-line summary (what monitoring systems
# display); details follow. Read-only: safe to run as any user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly OK=0 WARNING=1 CRITICAL=2 UNKNOWN=3

DISK_WARN=80;  DISK_CRIT=90
INODE_WARN=80; INODE_CRIT=90
MEM_WARN=85;   MEM_CRIT=95
LOAD_WARN=1.5; LOAD_CRIT=3.0   # 5-minute load average per CPU core
SERVICES=()
PROC_DIR="${PROC_DIR:-/proc}"

STATUS=${OK}
SUMMARY=()
DETAILS=()

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Check host health and exit with a Nagios-style status code.

Options:
  --disk-warn PCT    filesystem usage warning threshold   (default: ${DISK_WARN})
  --disk-crit PCT    filesystem usage critical threshold  (default: ${DISK_CRIT})
  --inode-warn PCT   inode usage warning threshold        (default: ${INODE_WARN})
  --inode-crit PCT   inode usage critical threshold       (default: ${INODE_CRIT})
  --mem-warn PCT     memory usage warning threshold       (default: ${MEM_WARN})
  --mem-crit PCT     memory usage critical threshold      (default: ${MEM_CRIT})
  --load-warn N      5-min load per core warning          (default: ${LOAD_WARN})
  --load-crit N      5-min load per core critical         (default: ${LOAD_CRIT})
  -s, --service NAME systemd unit that must be active (repeatable)
  -h, --help         show this help

Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (bad arguments or check error)
EOF
}

unknown() { echo "UNKNOWN - $*"; exit "${UNKNOWN}"; }

need_arg() { [[ $# -ge 2 && -n "$2" ]] || unknown "$1 requires an argument"; }
is_pct()   { [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( $1 <= 100 )); }
is_num()   { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk-warn)  need_arg "$@"; DISK_WARN="$2";  shift 2 ;;
            --disk-crit)  need_arg "$@"; DISK_CRIT="$2";  shift 2 ;;
            --inode-warn) need_arg "$@"; INODE_WARN="$2"; shift 2 ;;
            --inode-crit) need_arg "$@"; INODE_CRIT="$2"; shift 2 ;;
            --mem-warn)   need_arg "$@"; MEM_WARN="$2";   shift 2 ;;
            --mem-crit)   need_arg "$@"; MEM_CRIT="$2";   shift 2 ;;
            --load-warn)  need_arg "$@"; LOAD_WARN="$2";  shift 2 ;;
            --load-crit)  need_arg "$@"; LOAD_CRIT="$2";  shift 2 ;;
            -s|--service) need_arg "$@"; SERVICES+=("$2"); shift 2 ;;
            -h|--help)    usage; exit "${OK}" ;;
            *) usage >&2; unknown "unknown argument: $1" ;;
        esac
    done

    local pair w c
    for pair in "disk:${DISK_WARN}:${DISK_CRIT}" "inode:${INODE_WARN}:${INODE_CRIT}" "mem:${MEM_WARN}:${MEM_CRIT}"; do
        IFS=: read -r _ w c <<<"${pair}"
        if ! is_pct "${w}" || ! is_pct "${c}"; then
            unknown "${pair%%:*} thresholds must be integers 0-100"
        fi
        (( w < c )) || unknown "${pair%%:*} warning (${w}) must be lower than critical (${c})"
    done
    if ! is_num "${LOAD_WARN}" || ! is_num "${LOAD_CRIT}"; then
        unknown "load thresholds must be numbers"
    fi
    awk -v w="${LOAD_WARN}" -v c="${LOAD_CRIT}" 'BEGIN { exit !(w < c) }' \
        || unknown "load warning (${LOAD_WARN}) must be lower than critical (${LOAD_CRIT})"
}

# raise LEVEL MESSAGE - record a finding and escalate overall status.
raise() {
    local level="$1"; shift
    (( level > STATUS )) && STATUS=${level}
    SUMMARY+=("$*")
}

check_disk() {
    local mount pct ipct
    # -P for stable POSIX columns; -x skips pseudo filesystems.
    while read -r mount pct; do
        pct="${pct%\%}"
        DETAILS+=("disk ${mount} ${pct}%")
        if   (( pct >= DISK_CRIT )); then raise "${CRITICAL}" "${mount} ${pct}% used"
        elif (( pct >= DISK_WARN )); then raise "${WARNING}"  "${mount} ${pct}% used"
        fi
    done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR > 1 { print $6, $5 }')

    while read -r mount ipct; do
        [[ "${ipct}" == "-" ]] && continue   # filesystems without inode accounting (btrfs, xfs dynamic)
        ipct="${ipct%\%}"
        if   (( ipct >= INODE_CRIT )); then raise "${CRITICAL}" "${mount} inodes ${ipct}%"
        elif (( ipct >= INODE_WARN )); then raise "${WARNING}"  "${mount} inodes ${ipct}%"
        fi
    done < <(df -P -i -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR > 1 { print $6, $5 }')
}

check_memory() {
    local total avail pct
    total="$(awk '/^MemTotal:/ { print $2 }' "${PROC_DIR}/meminfo")"
    avail="$(awk '/^MemAvailable:/ { print $2 }' "${PROC_DIR}/meminfo")"
    [[ -n "${total}" && -n "${avail}" && "${total}" -gt 0 ]] || unknown "cannot read ${PROC_DIR}/meminfo"
    # MemAvailable accounts for reclaimable page cache; "free" alone would alarm constantly.
    pct=$(( (total - avail) * 100 / total ))
    DETAILS+=("memory ${pct}% used ($(( avail / 1024 )) MiB available)")
    if   (( pct >= MEM_CRIT )); then raise "${CRITICAL}" "memory ${pct}%"
    elif (( pct >= MEM_WARN )); then raise "${WARNING}"  "memory ${pct}%"
    fi
}

check_load() {
    local load5 cores per_core level
    load5="$(awk '{ print $2 }' "${PROC_DIR}/loadavg")"
    cores="$(nproc 2>/dev/null || echo 1)"
    per_core="$(awk -v l="${load5}" -v c="${cores}" 'BEGIN { printf "%.2f", l / c }')"
    DETAILS+=("load5 ${load5} on ${cores} core(s) = ${per_core}/core")
    level="$(awk -v p="${per_core}" -v w="${LOAD_WARN}" -v c="${LOAD_CRIT}" \
        'BEGIN { print (p >= c) ? 2 : (p >= w) ? 1 : 0 }')"
    (( level > 0 )) && raise "${level}" "load ${per_core}/core"
    return 0
}

check_services() {
    local svc state
    for svc in "${SERVICES[@]}"; do
        state="$(systemctl is-active "${svc}" 2>/dev/null || true)"
        DETAILS+=("service ${svc} ${state:-unknown}")
        [[ "${state}" == "active" ]] || raise "${CRITICAL}" "${svc} ${state:-unknown}"
    done
}

main() {
    parse_args "$@"
    check_disk
    check_memory
    check_load
    [[ ${#SERVICES[@]} -gt 0 ]] && check_services

    local label
    case "${STATUS}" in
        "${OK}")       label="OK" ;;
        "${WARNING}")  label="WARNING" ;;
        "${CRITICAL}") label="CRITICAL" ;;
    esac
    if [[ ${#SUMMARY[@]} -eq 0 ]]; then
        echo "${label} - all checks passed on $(uname -n)"
    else
        local joined
        joined="$(printf '%s; ' "${SUMMARY[@]}")"
        echo "${label} - ${joined%; }"
    fi
    printf '  %s\n' "${DETAILS[@]}"
    exit "${STATUS}"
}

main "$@"
