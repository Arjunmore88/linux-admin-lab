#!/usr/bin/env bats
# Tests for scripts/offboard-user.sh (argument handling and safety rails only)

setup() {
    load test_helper
}

@test "--help prints usage and exits 0" {
    run "$SCRIPTS/offboard-user.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "no --user is a usage error" {
    run "$SCRIPTS/offboard-user.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"at least one --user is required"* ]]
}

@test "invalid username is rejected before anything else" {
    run "$SCRIPTS/offboard-user.sh" --user 'rm -rf' --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid username"* ]]
}

@test "refuses to offboard root even in dry-run" {
    run "$SCRIPTS/offboard-user.sh" --user root --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"refusing to offboard system account root"* ]]
}

@test "unknown user fails cleanly" {
    run "$SCRIPTS/offboard-user.sh" --user zz-no-such-user --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}
