#!/usr/bin/env bash
#
# onboard-users.sh - create or update user accounts from a CSV file.
#
# CSV columns (header row required, '#' comments and blank lines ignored):
#   username,full_name,group,ssh_public_key,sudo,expiry
#
#   username        login name, lowercase, max 32 chars
#   full_name       GECOS comment (no commas)
#   group           supplementary team group, created if missing
#   ssh_public_key  one OpenSSH public key (accounts are key-only)
#   sudo            yes|no - managed via /etc/sudoers.d/90-lab-<user>
#   expiry          YYYY-MM-DD account expiry, or empty for none
#
# The script is idempotent: re-running it with the same CSV converges
# existing accounts instead of failing on them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly EXPECTED_HEADER="username,full_name,group,ssh_public_key,sudo,expiry"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
CSV_FILE=""
VALIDATE_ONLY=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --csv FILE [--dry-run] [--validate-only]

Create or update local user accounts from a CSV file.

Options:
  -c, --csv FILE       CSV file to process (required)
  -n, --dry-run        print the actions that would be taken, change nothing
  -V, --validate-only  validate the CSV and exit (no root needed)
  -h, --help           show this help

CSV header (exact):
  ${EXPECTED_HEADER}

Exit codes: 0 success, 1 runtime failure, 2 usage or CSV validation error
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--csv)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                CSV_FILE="$2"; shift 2 ;;
            -n|--dry-run)       DRY_RUN=1; shift ;;
            -V|--validate-only) VALIDATE_ONLY=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            *) usage >&2; die 2 "unknown argument: $1" ;;
        esac
    done
    [[ -n "${CSV_FILE}" ]] || { usage >&2; die 2 "--csv is required"; }
    [[ -r "${CSV_FILE}" ]] || die 2 "cannot read CSV file: ${CSV_FILE}"
}

# Validates every row and reports all problems at once, so whoever owns
# the CSV can fix it in a single pass. Returns the number of bad rows.
validate_csv() {
    local file="$1" lineno=0 errors=0 header_seen=0
    local -A seen=()
    local username full_name group key sudo expiry commas

    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ -z "${line// }" || "${line}" =~ ^[[:space:]]*# ]] && continue

        if [[ "${header_seen}" -eq 0 ]]; then
            header_seen=1
            if [[ "${line}" != "${EXPECTED_HEADER}" ]]; then
                err "line ${lineno}: bad header; expected '${EXPECTED_HEADER}'"
                errors=$((errors + 1))
                break
            fi
            continue
        fi

        commas="${line//[^,]/}"
        if [[ ${#commas} -ne 5 ]]; then
            err "line ${lineno}: expected 6 fields, found $(( ${#commas} + 1 )) (commas are not allowed inside values)"
            errors=$((errors + 1)); continue
        fi
        IFS=',' read -r username full_name group key sudo expiry <<<"${line}"
        if ! is_valid_username "${username}"; then
            err "line ${lineno}: invalid username '${username}'"
            errors=$((errors + 1))
        elif [[ -n "${seen[${username}]:-}" ]]; then
            err "line ${lineno}: duplicate username '${username}' (first on line ${seen[${username}]})"
            errors=$((errors + 1))
        else
            seen[${username}]="${lineno}"
        fi
        if [[ -z "${full_name}" ]]; then
            err "line ${lineno}: full_name is empty"
            errors=$((errors + 1))
        fi
        if ! is_valid_username "${group}"; then
            err "line ${lineno}: invalid group '${group}'"
            errors=$((errors + 1))
        fi
        if [[ ! "${key}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com)\ [A-Za-z0-9+/=]+(\ .*)?$ ]]; then
            err "line ${lineno}: ssh_public_key is missing or not an OpenSSH public key"
            errors=$((errors + 1))
        fi
        if [[ "${sudo}" != "yes" && "${sudo}" != "no" ]]; then
            err "line ${lineno}: sudo must be 'yes' or 'no', got '${sudo}'"
            errors=$((errors + 1))
        fi
        if [[ -n "${expiry}" ]]; then
            if [[ ! "${expiry}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "${expiry}" >/dev/null 2>&1; then
                err "line ${lineno}: expiry '${expiry}' is not a valid YYYY-MM-DD date"
                errors=$((errors + 1))
            elif [[ "$(date -d "${expiry}" +%s)" -le "$(date +%s)" ]]; then
                err "line ${lineno}: expiry ${expiry} is in the past"
                errors=$((errors + 1))
            fi
        fi
    done <"${file}"

    if [[ "${header_seen}" -eq 0 ]]; then
        err "CSV is empty (no header found)"
        errors=$((errors + 1))
    fi
    return $(( errors > 255 ? 255 : errors ))
}

ensure_group() {
    local group="$1"
    if getent group "${group}" >/dev/null; then
        return 0
    fi
    log "creating group ${group}"
    run groupadd "${group}"
}

ensure_user() {
    local username="$1" full_name="$2" group="$3" expiry="$4"
    if id "${username}" >/dev/null 2>&1; then
        log "user ${username} exists; converging attributes"
        run usermod -c "${full_name}" -a -G "${group}" "${username}"
    else
        log "creating user ${username} (${full_name})"
        # No password is set: accounts are SSH-key only. useradd leaves the
        # password field locked ('!'), which still permits key logins.
        run useradd -m -s /bin/bash -c "${full_name}" -G "${group}" "${username}"
    fi
    # chage -E -1 removes an expiry if the CSV no longer has one.
    run chage -E "${expiry:--1}" "${username}"
}

ensure_ssh_key() {
    local username="$1" key="$2" home ssh_dir auth_keys
    if [[ "${DRY_RUN}" == "1" ]] && ! id "${username}" >/dev/null 2>&1; then
        home="/home/${username}"
    else
        home="$(getent passwd "${username}" | cut -d: -f6)"
    fi
    ssh_dir="${home}/.ssh"
    auth_keys="${ssh_dir}/authorized_keys"

    run install -d -m 0700 -o "${username}" -g "${username}" "${ssh_dir}"
    if [[ -f "${auth_keys}" ]] && grep -qxF -- "${key}" "${auth_keys}"; then
        log "ssh key for ${username} already present"
    elif [[ "${DRY_RUN}" == "1" ]]; then
        _log DRY-RUN "append ssh key to ${auth_keys}"
    else
        printf '%s\n' "${key}" >>"${auth_keys}"
        log "added ssh key for ${username}"
    fi
    run chown "${username}:${username}" "${auth_keys}"
    run chmod 0600 "${auth_keys}"
}

ensure_sudo() {
    local username="$1" sudo="$2"
    local target="${SUDOERS_DIR}/90-lab-${username}"
    if [[ "${sudo}" == "no" ]]; then
        if [[ -e "${target}" ]]; then
            log "revoking sudo for ${username}"
            run rm -f "${target}"
        fi
        return 0
    fi
    # Key-only accounts have no password to type, hence NOPASSWD. Access is
    # still auditable through journald / auth.log.
    local rule="${username} ALL=(ALL) NOPASSWD: ALL"
    if [[ -f "${target}" ]] && grep -qxF -- "${rule}" "${target}"; then
        log "sudo rule for ${username} already in place"
        return 0
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
        _log DRY-RUN "write '${rule}' to ${target} (mode 0440, validated by visudo)"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    printf '# Managed by linux-admin-lab onboard-users.sh - do not edit by hand\n%s\n' "${rule}" >"${tmp}"
    # Never install a sudoers fragment that visudo rejects: a syntax error
    # in /etc/sudoers.d breaks sudo for everyone on the host.
    if ! visudo -cqf "${tmp}"; then
        rm -f "${tmp}"
        die 1 "generated sudoers rule for ${username} failed visudo validation"
    fi
    install -m 0440 -o root -g root "${tmp}" "${target}"
    rm -f "${tmp}"
    log "granted sudo to ${username}"
}

main() {
    parse_args "$@"

    log "validating ${CSV_FILE}"
    local bad=0
    validate_csv "${CSV_FILE}" || bad=$?
    if [[ "${bad}" -gt 0 ]]; then
        die 2 "CSV validation failed with ${bad} error(s); nothing was changed"
    fi
    log "CSV is valid"
    [[ "${VALIDATE_ONLY}" -eq 1 ]] && exit 0

    require_root
    detect_distro
    log "detected ${DISTRO_ID} (${DISTRO_FAMILY} family)"

    local count=0 username full_name group key sudo expiry
    while IFS=',' read -r username full_name group key sudo expiry; do
        expiry="${expiry%$'\r'}"
        ensure_group "${group}"
        ensure_user "${username}" "${full_name}" "${group}" "${expiry}"
        ensure_ssh_key "${username}" "${key}"
        ensure_sudo "${username}" "${sudo}"
        count=$((count + 1))
    done < <(grep -vE '^[[:space:]]*(#|$)' "${CSV_FILE}" | tail -n +2)

    log "processed ${count} account(s)"
}

main "$@"
