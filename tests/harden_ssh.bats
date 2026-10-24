#!/usr/bin/env bats
# Tests for scripts/harden-ssh.sh. The config renderer is exercised against
# temporary files; nothing touches /etc/ssh.

setup() {
    load test_helper
    CFG="$BATS_TEST_TMPDIR/sshd_config"
}

render() {
    bash -c 'source "$SCRIPTS/harden-ssh.sh"; render_inplace "$1" "$(baseline_settings)"' _ "$1"
}

@test "--help prints usage and exits 0" {
    run "$SCRIPTS/harden-ssh.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "invalid port is rejected" {
    run "$SCRIPTS/harden-ssh.sh" --port 70000 --print
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid port"* ]]
}

@test "--print shows the baseline without needing root" {
    run "$SCRIPTS/harden-ssh.sh" --print --allow-groups "cloudops sshusers"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PermitRootLogin no"* ]]
    [[ "$output" == *"PasswordAuthentication no"* ]]
    [[ "$output" == *"AllowGroups cloudops sshusers"* ]]
}

@test "renderer replaces active and commented keywords exactly once" {
    printf '#PermitRootLogin prohibit-password\nPasswordAuthentication yes\nPasswordAuthentication yes\nUsePAM yes\n' >"$CFG"
    run render "$CFG"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^PermitRootLogin no$' <<<"$output")" -eq 1 ]
    [ "$(grep -c '^PasswordAuthentication' <<<"$output")" -eq 1 ]
    [[ "$output" == *"UsePAM yes"* ]]
}

@test "renderer inserts missing keywords before the first Match block" {
    printf 'UsePAM yes\nMatch User backup\n    PasswordAuthentication yes\n' >"$CFG"
    run render "$CFG"
    [ "$status" -eq 0 ]
    match_line=$(grep -n '^Match User backup' <<<"$output" | cut -d: -f1)
    maxauth_line=$(grep -n '^MaxAuthTries 3' <<<"$output" | cut -d: -f1)
    [ "$maxauth_line" -lt "$match_line" ]
    # The Match block's own override is preserved untouched.
    [[ "$output" == *"    PasswordAuthentication yes"* ]]
}

@test "renderer is idempotent" {
    printf '#Port 22\nX11Forwarding yes\nSubsystem sftp /usr/lib/openssh/sftp-server\n' >"$CFG"
    render "$CFG" >"$CFG.1"
    render "$CFG.1" >"$CFG.2"
    cmp -s "$CFG.1" "$CFG.2"
}

@test "rendered config passes sshd -t when sshd is available" {
    SSHD="$(command -v sshd || echo /usr/sbin/sshd)"
    [ -x "$SSHD" ] || skip "sshd not installed"
    printf '#PermitRootLogin yes\nUsePAM yes\nSubsystem sftp internal-sftp\n' >"$CFG"
    render "$CFG" >"$CFG.new"
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/hostkey"
    run "$SSHD" -t -f "$CFG.new" -h "$BATS_TEST_TMPDIR/hostkey"
    [ "$status" -eq 0 ]
}
