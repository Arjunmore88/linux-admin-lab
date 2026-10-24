#!/usr/bin/env bash
#
# offboard-user.sh - disable a departing user's access and archive their home.
#
# Order of operations matters: access is cut first (lock, expire, kill
# sessions, revoke sudo) and data is archived second, so a slow archive
# never leaves a window where the account is still usable.
#
# The account itself is kept (locked) by default so file ownership stays
# resolvable during the retention period. Pass --delete to remove it after
# a successful archive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
ARCHIVE_DIR="/var/backups/offboarded"
MIN_UID=1000
DELETE_ACCOUNT=0
USERS=()

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --user NAME [--user NAME ...] [options]

Lock a user account, revoke access and archive the home directory.

Options:
  -u, --user NAME        account to offboard (repeatable)
  -a, --archive-dir DIR  where home archives are written (default: ${ARCHIVE_DIR})
      --delete           remove the account after a successful archive
  -n, --dry-run          print the actions that would be taken, change nothing
  -h, --help             show this help

Safety: refuses system accounts (UID < ${MIN_UID}) and root.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--user)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                USERS+=("$2"); shift 2 ;;
            -a|--archive-dir)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                ARCHIVE_DIR="$2"; shift 2 ;;
            --delete)     DELETE_ACCOUNT=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die 2 "unknown argument: $1" ;;
        esac
    done
    [[ ${#USERS[@]} -gt 0 ]] || { usage >&2; die 2 "at least one --user is required"; }
    local u
    for u in "${USERS[@]}"; do
        is_valid_username "${u}" || die 2 "invalid username: ${u}"
    done
}

preflight_user() {
    local username="$1" uid
    id "${username}" >/dev/null 2>&1 || die 1 "user ${username} does not exist"
    uid="$(id -u "${username}")"
    if [[ "${username}" == "root" || "${uid}" -lt "${MIN_UID}" ]]; then
        die 2 "refusing to offboard system account ${username} (uid ${uid})"
    fi
}

revoke_access() {
    local username="$1" nologin
    nologin="$(command -v nologin || echo /usr/sbin/nologin)"

    log "locking ${username}: password lock, account expiry, nologin shell"
    run usermod -L -s "${nologin}" "${username}"
    run chage -E 0 "${username}"

    if [[ -e "${SUDOERS_DIR}/90-lab-${username}" ]]; then
        log "removing sudo rule for ${username}"
        run rm -f "${SUDOERS_DIR}/90-lab-${username}"
    fi

    # Remove crontab and running processes so nothing keeps acting as the user.
    if crontab -l -u "${username}" >/dev/null 2>&1; then
        log "removing crontab for ${username}"
        run crontab -r -u "${username}"
    fi
    if pgrep -u "${username}" >/dev/null 2>&1; then
        log "terminating sessions and processes for ${username}"
        if command -v loginctl >/dev/null 2>&1; then
            run loginctl terminate-user "${username}" || true
        fi
        run pkill -KILL -u "${username}" || true
    fi
}

archive_home() {
    local username="$1" home archive
    home="$(getent passwd "${username}" | cut -d: -f6)"
    if [[ -z "${home}" || ! -d "${home}" ]]; then
        warn "home directory for ${username} not found; skipping archive"
        return 0
    fi
    archive="${ARCHIVE_DIR}/${username}-$(timestamp).tar.gz"

    run install -d -m 0700 -o root -g root "${ARCHIVE_DIR}"
    log "archiving ${home} -> ${archive}"
    run tar --numeric-owner -czf "${archive}" -C "$(dirname "${home}")" "$(basename "${home}")"
    if [[ "${DRY_RUN}" != "1" ]]; then
        chmod 0600 "${archive}"
        (cd "${ARCHIVE_DIR}" && sha256sum "$(basename "${archive}")" >"$(basename "${archive}").sha256")
        tar -tzf "${archive}" >/dev/null || die 1 "archive ${archive} failed integrity check"
        log "archive verified ($(du -h "${archive}" | cut -f1))"
    fi
}

main() {
    parse_args "$@"
    require_root
    detect_distro

    local u
    for u in "${USERS[@]}"; do
        preflight_user "${u}"
    done

    for u in "${USERS[@]}"; do
        log "=== offboarding ${u} ==="
        revoke_access "${u}"
        archive_home "${u}"
        if [[ "${DELETE_ACCOUNT}" -eq 1 ]]; then
            log "deleting account ${u} and home directory"
            run userdel -r "${u}"
        fi
        log "offboarding of ${u} complete"
    done
}

main "$@"
