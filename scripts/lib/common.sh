# shellcheck shell=bash
#
# common.sh - shared helpers for the linux-admin-lab scripts.
#
# Source this file; do not execute it. It provides:
#   log / warn / err / die    timestamped logging to stderr (+ optional file)
#   run                       execute a command, or print it when DRY_RUN=1
#   require_root              abort unless EUID 0 (skipped in dry-run)
#   detect_distro             sets DISTRO_FAMILY=debian|rhel and DISTRO_ID
#   is_valid_username         POSIX-safe login name check
#
# Exit code convention used across the repo:
#   0 success, 1 runtime failure, 2 usage / validation error

[[ -n "${_LAB_COMMON_LOADED:-}" ]] && return 0
_LAB_COMMON_LOADED=1

: "${DRY_RUN:=0}"
: "${LOG_FILE:=}"
: "${OS_RELEASE_FILE:=/etc/os-release}"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${0}")}"

_log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%dT%H:%M:%S%z') ${SCRIPT_NAME} [${level}] $*"
    printf '%s\n' "${line}" >&2
    if [[ -n "${LOG_FILE}" ]]; then
        # Never let a logging problem kill the script.
        printf '%s\n' "${line}" >>"${LOG_FILE}" 2>/dev/null || true
    fi
}

log()  { _log INFO "$@"; }
warn() { _log WARN "$@"; }
err()  { _log ERROR "$@"; }

die() {
    local code=1
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then code="$1"; shift; fi
    err "$@"
    exit "${code}"
}

# run CMD [ARGS...]
# Executes the command, or prints it (shell-quoted) when DRY_RUN=1.
run() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        local quoted
        printf -v quoted '%q ' "$@"
        _log DRY-RUN "${quoted% }"
        return 0
    fi
    "$@"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            warn "not running as root; continuing because --dry-run is set"
            return 0
        fi
        die 1 "this script must be run as root (try: sudo ${SCRIPT_NAME} ...)"
    fi
}

# Populates DISTRO_ID (e.g. ubuntu, rhel, rocky) and DISTRO_FAMILY (debian|rhel).
detect_distro() {
    [[ -r "${OS_RELEASE_FILE}" ]] || die 1 "cannot read ${OS_RELEASE_FILE}; unsupported system"
    local id="" id_like=""
    # Parse instead of sourcing so a malformed file cannot execute code.
    id="$(sed -n 's/^ID=//p' "${OS_RELEASE_FILE}" | tr -d '"' | head -n1)"
    id_like="$(sed -n 's/^ID_LIKE=//p' "${OS_RELEASE_FILE}" | tr -d '"' | head -n1)"
    DISTRO_ID="${id}"
    case " ${id} ${id_like} " in
        *" debian "*|*" ubuntu "*)                         DISTRO_FAMILY="debian" ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) DISTRO_FAMILY="rhel" ;;
        *) die 1 "unsupported distribution: ID=${id} ID_LIKE=${id_like}" ;;
    esac
    export DISTRO_ID DISTRO_FAMILY
}

is_valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

timestamp() { date '+%Y%m%d-%H%M%S'; }
