#!/usr/bin/env bash
#
# backup.sh - compressed tar backups with SHA-256 checksums and retention.
#
# Each run produces:
#   <dest>/<name>-<YYYYmmdd-HHMMSS>.tar.gz
#   <dest>/<name>-<YYYYmmdd-HHMMSS>.tar.gz.sha256
#
# The archive is verified (checksum + tar listing) before old backups are
# pruned, so a failed run never deletes the last good copy. A lock file
# prevents overlapping runs when the job is slower than its schedule.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SOURCES=()
DEST=""
NAME="backup"
RETENTION_DAYS=14
VERIFY_ONLY=""

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --source DIR [--source DIR ...] --dest DIR [options]
       ${SCRIPT_NAME} --verify ARCHIVE

Create a checksummed tar.gz backup and prune old ones.

Options:
  -s, --source DIR       directory or file to back up (repeatable)
  -d, --dest DIR         directory to write backups into
  -N, --name NAME        archive name prefix (default: ${NAME})
  -r, --retention DAYS   delete this job's backups older than DAYS (default: ${RETENTION_DAYS}, 0 = keep all)
      --verify ARCHIVE   verify an existing archive against its .sha256 and exit
  -n, --dry-run          show what would be archived and pruned, change nothing
  -h, --help             show this help

Example:
  sudo ${SCRIPT_NAME} -s /etc -s /var/www -d /srv/backups -N web01-config -r 30
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--source)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                SOURCES+=("$2"); shift 2 ;;
            -d|--dest)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                DEST="$2"; shift 2 ;;
            -N|--name)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                NAME="$2"; shift 2 ;;
            -r|--retention)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                RETENTION_DAYS="$2"; shift 2 ;;
            --verify)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                VERIFY_ONLY="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die 2 "unknown argument: $1" ;;
        esac
    done
    [[ -n "${VERIFY_ONLY}" ]] && return 0

    [[ ${#SOURCES[@]} -gt 0 ]] || { usage >&2; die 2 "at least one --source is required"; }
    [[ -n "${DEST}" ]]         || { usage >&2; die 2 "--dest is required"; }
    [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] || die 2 "--retention must be a non-negative integer"
    [[ "${NAME}" =~ ^[A-Za-z0-9._-]+$ ]]  || die 2 "--name may only contain letters, digits, '.', '_' and '-'"
    local s
    for s in "${SOURCES[@]}"; do
        [[ -e "${s}" ]] || die 2 "source does not exist: ${s}"
    done
}

verify_archive() {
    local archive="$1"
    [[ -f "${archive}" ]]        || die 1 "archive not found: ${archive}"
    [[ -f "${archive}.sha256" ]] || die 1 "checksum file not found: ${archive}.sha256"
    (cd "$(dirname "${archive}")" && sha256sum --quiet -c "$(basename "${archive}").sha256") \
        || die 1 "checksum mismatch for ${archive}"
    tar -tzf "${archive}" >/dev/null || die 1 "archive is not a readable tar.gz: ${archive}"
    log "verified ${archive}"
}

create_backup() {
    local archive="$1" tmp="${1}.partial"
    log "archiving ${SOURCES[*]} -> ${archive}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        _log DRY-RUN "tar -czf ${archive} ${SOURCES[*]}"
        return 0
    fi
    # Write to .partial and rename, so an interrupted run never leaves
    # something that looks like a complete backup.
    # Store paths relative to / (restore with: tar -xzf ARCHIVE -C /).
    local rel=() s
    for s in "${SOURCES[@]}"; do
        s="$(realpath -- "${s}")"
        rel+=("${s#/}")
    done
    tar --warning=no-file-changed -czf "${tmp}" -C / "${rel[@]}" || {
        local rc=$?
        # GNU tar exits 1 when files changed while being read; that is
        # acceptable for a live system. Anything else is fatal.
        if [[ ${rc} -ne 1 ]]; then rm -f "${tmp}"; die 1 "tar failed with exit code ${rc}"; fi
        warn "some files changed while being archived"
    }
    mv "${tmp}" "${archive}"
    chmod 0600 "${archive}"
    (cd "$(dirname "${archive}")" && sha256sum "$(basename "${archive}")" >"$(basename "${archive}").sha256")
    verify_archive "${archive}"
    log "backup size $(du -h "${archive}" | cut -f1)"
}

prune_old() {
    if [[ "${RETENTION_DAYS}" -eq 0 ]]; then
        log "retention disabled; keeping all backups"
        return 0
    fi
    local f count=0
    while IFS= read -r -d '' f; do
        log "pruning $(basename "${f}") (older than ${RETENTION_DAYS} days)"
        run rm -f -- "${f}" "${f}.sha256"
        count=$((count + 1))
    done < <(find "${DEST}" -maxdepth 1 -type f -name "${NAME}-*.tar.gz" -mtime "+$((RETENTION_DAYS - 1))" -print0)
    log "pruned ${count} old backup(s)"
}

main() {
    parse_args "$@"
    if [[ -n "${VERIFY_ONLY}" ]]; then
        verify_archive "${VERIFY_ONLY}"
        exit 0
    fi

    # Backing up system paths needs root; backing up your own data does not.
    if [[ "${EUID}" -ne 0 ]]; then
        warn "not running as root; files unreadable by $(id -un) will be skipped or fail"
    fi

    run mkdir -p "${DEST}"
    if [[ "${DRY_RUN}" != "1" ]]; then
        exec 9>"${DEST}/.${NAME}.lock"
        flock -n 9 || die 1 "another ${NAME} backup is already running"
    fi

    local archive
    archive="${DEST}/${NAME}-$(timestamp).tar.gz"
    create_backup "${archive}"
    prune_old
    log "backup job ${NAME} finished"
}

main "$@"
