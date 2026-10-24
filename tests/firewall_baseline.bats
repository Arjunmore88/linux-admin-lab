#!/usr/bin/env bats
# Tests for scripts/firewall-baseline.sh (arguments and dry-run plan only)

setup() {
    load test_helper
}

@test "--help prints usage and exits 0" {
    run "$SCRIPTS/firewall-baseline.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"default-deny"* ]]
}

@test "malformed --allow spec is rejected" {
    run "$SCRIPTS/firewall-baseline.sh" --allow 443
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid port spec '443'"* ]]
}

@test "out-of-range port is rejected" {
    run "$SCRIPTS/firewall-baseline.sh" --allow 99999/tcp
    [ "$status" -eq 2 ]
}

@test "unknown backend is rejected" {
    run "$SCRIPTS/firewall-baseline.sh" --backend iptables
    [ "$status" -eq 2 ]
}

@test "ufw dry-run opens SSH before enabling default deny" {
    [ "$(id -u)" -ne 0 ] || skip "dry-run root bypass only applies to non-root"
    run "$SCRIPTS/firewall-baseline.sh" --backend ufw --ssh-port 2222 --allow 443/tcp --dry-run
    [ "$status" -eq 0 ]
    ssh_line=$(grep -n 'DRY-RUN\] ufw allow 2222/tcp' <<<"$output" | head -n1 | cut -d: -f1)
    deny_line=$(grep -n 'DRY-RUN\] ufw default deny incoming' <<<"$output" | cut -d: -f1)
    enable_line=$(grep -n 'DRY-RUN\] ufw --force enable' <<<"$output" | cut -d: -f1)
    [ -n "$ssh_line" ] && [ -n "$deny_line" ] && [ -n "$enable_line" ]
    [ "$ssh_line" -lt "$deny_line" ]
    [ "$deny_line" -lt "$enable_line" ]
    [[ "$output" == *"ufw allow 443/tcp"* ]]
}
