#!/usr/bin/env bash
#
# firewall-baseline.sh - default-deny inbound firewall using the distro's
# native front end: ufw on Ubuntu/Debian, firewalld on RHEL family.
#
# SSH is always allowed BEFORE the default-deny policy is enabled, so the
# script cannot cut off the session that is running it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SSH_PORT=22
ALLOW_PORTS=()
BACKEND=""

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Apply a default-deny inbound firewall baseline.

Options:
  -s, --ssh-port N       SSH port to keep open (default: 22)
  -a, --allow PORT/PROTO additional inbound port to allow, e.g. 443/tcp (repeatable)
  -b, --backend NAME     force ufw or firewalld instead of auto-detecting
  -n, --dry-run          print the commands that would run, change nothing
  -h, --help             show this help

Examples:
  sudo ${SCRIPT_NAME} --allow 80/tcp --allow 443/tcp
  sudo ${SCRIPT_NAME} --ssh-port 2222 --dry-run
EOF
}

valid_port_spec() {
    [[ "$1" =~ ^([0-9]{1,5})/(tcp|udp)$ ]] && (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= 65535 ))
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--ssh-port)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                SSH_PORT="$2"; shift 2 ;;
            -a|--allow)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                valid_port_spec "$2" || die 2 "invalid port spec '$2' (expected e.g. 443/tcp)"
                ALLOW_PORTS+=("$2"); shift 2 ;;
            -b|--backend)
                [[ $# -ge 2 ]] || die 2 "$1 requires an argument"
                [[ "$2" == "ufw" || "$2" == "firewalld" ]] || die 2 "backend must be ufw or firewalld"
                BACKEND="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die 2 "unknown argument: $1" ;;
        esac
    done
    valid_port_spec "${SSH_PORT}/tcp" || die 2 "invalid ssh port: ${SSH_PORT}"
}

detect_backend() {
    [[ -n "${BACKEND}" ]] && return 0
    # Prefer whatever is already running; fall back to the distro default.
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        BACKEND="firewalld"
    elif command -v ufw >/dev/null 2>&1; then
        BACKEND="ufw"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        BACKEND="firewalld"
    elif [[ "${DISTRO_FAMILY}" == "debian" ]]; then
        die 1 "ufw not installed (apt-get install ufw)"
    else
        die 1 "firewalld not installed (dnf install firewalld)"
    fi
    # Two managers fighting over netfilter is a classic outage cause.
    if [[ "${BACKEND}" == "ufw" ]] && systemctl is-active --quiet firewalld 2>/dev/null; then
        die 1 "both ufw and firewalld present and firewalld is active; pick one with --backend"
    fi
}

apply_ufw() {
    log "configuring ufw"
    run ufw allow "${SSH_PORT}/tcp" comment 'ssh (baseline)'
    run ufw limit "${SSH_PORT}/tcp"
    local p
    for p in "${ALLOW_PORTS[@]}"; do
        run ufw allow "${p}" comment 'baseline'
    done
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw logging low
    run ufw --force enable
    [[ "${DRY_RUN}" == "1" ]] || ufw status verbose
}

apply_firewalld() {
    log "configuring firewalld"
    run systemctl enable --now firewalld
    local zone
    zone="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
    log "using default zone ${zone}"
    if [[ "${SSH_PORT}" == "22" ]]; then
        run firewall-cmd --permanent --zone="${zone}" --add-service=ssh
    else
        run firewall-cmd --permanent --zone="${zone}" --add-port="${SSH_PORT}/tcp"
    fi
    local p
    for p in "${ALLOW_PORTS[@]}"; do
        run firewall-cmd --permanent --zone="${zone}" --add-port="${p}"
    done
    # cockpit and dhcpv6-client are opened by default on RHEL; not part of our baseline.
    local svc
    for svc in cockpit dhcpv6-client; do
        if firewall-cmd --permanent --zone="${zone}" --query-service="${svc}" >/dev/null 2>&1; then
            run firewall-cmd --permanent --zone="${zone}" --remove-service="${svc}"
        fi
    done
    run firewall-cmd --permanent --zone="${zone}" --set-target=default
    run firewall-cmd --reload
    [[ "${DRY_RUN}" == "1" ]] || firewall-cmd --zone="${zone}" --list-all
}

main() {
    parse_args "$@"
    require_root
    detect_distro
    detect_backend
    log "distro=${DISTRO_ID} family=${DISTRO_FAMILY} backend=${BACKEND} ssh_port=${SSH_PORT} extra=[${ALLOW_PORTS[*]:-}]"
    case "${BACKEND}" in
        ufw)       apply_ufw ;;
        firewalld) apply_firewalld ;;
    esac
    log "firewall baseline applied"
}

main "$@"
