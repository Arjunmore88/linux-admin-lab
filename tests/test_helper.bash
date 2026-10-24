# shellcheck shell=bash
# Shared setup for all bats files.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SCRIPTS="${REPO_ROOT}/scripts"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
export REPO_ROOT SCRIPTS FIXTURES

# Pin distro detection so results do not depend on the CI runner image.
export OS_RELEASE_FILE="${FIXTURES}/os-release-ubuntu"

# Writes a CSV with the valid header plus the given rows.
write_csv() {
    local file="$1"; shift
    printf 'username,full_name,group,ssh_public_key,sudo,expiry\n' >"${file}"
    printf '%s\n' "$@" >>"${file}"
}

VALID_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY0000000000000000000000000000000 test@ci"
export VALID_KEY
