#!/usr/bin/env bash
#
# harden-ssh.sh - apply the team SSH baseline to sshd, safely and idempotently.
#
# Where the settings go:
#   * If sshd_config includes /etc/ssh/sshd_config.d/*.conf (Ubuntu 22.04+,
#     RHEL 9) the baseline is written to 00-baseline-hardening.conf. sshd uses
#     the FIRST value it sees for a keyword, so the 00- prefix wins over
#     vendor drop-ins such as 50-cloud-init.conf.
#   * Otherwise the keywords are edited in place in sshd_config.
#
# Safety:
#   * a timestamped backup is taken before any change
#   * the new config is validated with `sshd -t`; on failure the backup is
#     restored and sshd is NOT reloaded
#   * reload (not restart) keeps existing sessions alive
#   * refuses to disable password auth if the invoking admin has no
#     authorized_keys (override with --force)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SSHD_CONFIG="/etc/ssh/sshd_config"
DROPIN_NAME="00-baseline-hardening.conf"
SSH_PORT=22
ALLOW_GROUPS=""
FORCE=0
PRINT_ONLY=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Apply the SSH hardening baseline and reload sshd if anything changed.

Options:
  -p, --port N            SSH port (default: 22)
  -g, --allow-groups LIST space-separated groups allowed to log in (AllowGroups)
  -c, --config PATH       sshd_config path (default: ${SSHD_CONFIG})
      --print             print the baseline settings and exit (no root needed)
  -f, --force             skip the authorized_keys lockout check
  -n, --dry-run           show the diff that would be applied, change nothing
  -h, --help              show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                SSH_PORT="$2"; shift 2 ;;
            -g|--allow-groups)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                ALLOW_GROUPS="$2"; shift 2 ;;
            -c|--config)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                SSHD_CONFIG="$2"; shift 2 ;;
            --print)      PRINT_ONLY=1; shift ;;
            -f|--force)   FORCE=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die 2 "unknown argument: $1" ;;
        esac
    done
    if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        die 2 "invalid port: ${SSH_PORT}"
    fi
}

# The baseline, one "Keyword value" per line. Keep this list short and
# justified; every line here is something the team agreed to enforce.
baseline_settings() {
    cat <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
LogLevel VERBOSE
EOF
    if [[ -n "${ALLOW_GROUPS}" ]]; then
        printf 'AllowGroups %s\n' "${ALLOW_GROUPS}"
    fi
}

uses_dropin_dir() {
    grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CONFIG}"
}

# Rewrites keywords in a full sshd_config: replaces the first active or
# commented occurrence of each keyword, and inserts any missing keywords
# just before the first Match block (or at the end if there is none), since
# settings after a Match line only apply to that Match. Lines inside Match
# blocks are left untouched.
render_inplace() {
    local src="$1" settings="$2"
    SETTINGS="${settings}" awk '
        BEGIN {
            n = split(ENVIRON["SETTINGS"], lines, "\n")
            for (i = 1; i <= n; i++) {
                if (lines[i] == "") continue
                split(lines[i], kv, " ")
                key = tolower(kv[1]); want[key] = lines[i]; order[++cnt] = key
            }
        }
        function emit_missing(   i) {
            for (i = 1; i <= cnt; i++)
                if (!(order[i] in done)) { print want[order[i]]; done[order[i]] = 1 }
        }
        /^[[:space:]]*Match[[:space:]]/ && !in_match { emit_missing(); in_match = 1 }
        {
            if (!in_match) {
                line = $0; sub(/^[[:space:]]*#?[[:space:]]*/, "", line)
                split(line, f, /[[:space:]]+/); key = tolower(f[1])
                if (key in want) {
                    if (!(key in done)) { print want[key]; done[key] = 1 }
                    next
                }
            }
            print
        }
        END { emit_missing() }
    ' "${src}"
}

lockout_guard() {
    [[ "${FORCE}" -eq 1 ]] && return 0
    local admin="${SUDO_USER:-}" home
    if [[ -z "${admin}" || "${admin}" == "root" ]]; then
        warn "cannot determine invoking admin (run via sudo); skipping lockout check"
        return 0
    fi
    home="$(getent passwd "${admin}" | cut -d: -f6)"
    if [[ ! -s "${home}/.ssh/authorized_keys" ]]; then
        die 1 "${admin} has no ${home}/.ssh/authorized_keys; disabling password auth would lock you out (use --force to override)"
    fi
}

reload_sshd() {
    local unit="sshd"
    [[ "${DISTRO_FAMILY}" == "debian" ]] && unit="ssh"
    log "reloading ${unit}.service"
    run systemctl reload "${unit}"
}

main() {
    parse_args "$@"
    if [[ "${PRINT_ONLY}" -eq 1 ]]; then
        baseline_settings
        exit 0
    fi

    require_root
    detect_distro
    [[ -r "${SSHD_CONFIG}" ]] || die 1 "cannot read ${SSHD_CONFIG}"
    command -v sshd >/dev/null 2>&1 || PATH="${PATH}:/usr/sbin"
    command -v sshd >/dev/null 2>&1 || die 1 "sshd binary not found"

    local settings target candidate
    settings="$(baseline_settings)"
    candidate="$(mktemp)"
    trap 'rm -f "${candidate}"' EXIT

    if uses_dropin_dir; then
        target="$(dirname "${SSHD_CONFIG}")/sshd_config.d/${DROPIN_NAME}"
        log "sshd_config includes sshd_config.d; managing ${target}"
        printf '# Managed by linux-admin-lab harden-ssh.sh - do not edit by hand\n%s\n' "${settings}" >"${candidate}"
    else
        target="${SSHD_CONFIG}"
        log "no drop-in directory in use; editing ${target} in place"
        render_inplace "${SSHD_CONFIG}" "${settings}" >"${candidate}"
    fi

    if [[ -f "${target}" ]] && cmp -s "${candidate}" "${target}"; then
        log "already compliant; nothing to do"
        exit 0
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        log "changes that would be applied to ${target}:"
        if [[ -f "${target}" ]]; then
            diff -u "${target}" "${candidate}" || true
        else
            diff -u /dev/null "${candidate}" || true
        fi
        exit 0
    fi

    lockout_guard

    local backup=""
    if [[ -f "${target}" ]]; then
        backup="${target}.bak.$(timestamp)"
        cp -p "${target}" "${backup}"
        log "backup written to ${backup}"
    fi
    install -m 0600 -o root -g root "${candidate}" "${target}"

    if ! sshd -t; then
        err "sshd -t rejected the new configuration; rolling back"
        if [[ -n "${backup}" ]]; then cp -p "${backup}" "${target}"; else rm -f "${target}"; fi
        sshd -t || err "configuration still invalid after rollback - investigate before closing your session"
        exit 1
    fi
    log "sshd -t passed"
    reload_sshd
    log "SSH baseline applied. Keep this session open and test a NEW login before disconnecting."
}

# Allow tests to source this file for its functions without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
