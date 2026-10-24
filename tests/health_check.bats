#!/usr/bin/env bats
# Tests for scripts/health-check.sh. The script is read-only, so it is run
# for real, with /proc inputs swapped for fixtures via PROC_DIR.

setup() {
    load test_helper
    # Disk thresholds set so real runner disks never trip them.
    RELAXED_DISK=(--disk-warn 99 --disk-crit 100 --inode-warn 99 --inode-crit 100)
}

@test "--help prints usage and exits 0" {
    run "$SCRIPTS/health-check.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nagios-style"* ]]
}

@test "unknown argument exits 3 (UNKNOWN)" {
    run "$SCRIPTS/health-check.sh" --nope
    [ "$status" -eq 3 ]
    [[ "$output" == *"UNKNOWN - unknown argument: --nope"* ]]
}

@test "warning threshold must be below critical" {
    run "$SCRIPTS/health-check.sh" --disk-warn 95 --disk-crit 90
    [ "$status" -eq 3 ]
    [[ "$output" == *"disk warning (95) must be lower than critical (90)"* ]]
}

@test "non-numeric threshold exits 3" {
    run "$SCRIPTS/health-check.sh" --mem-warn eighty
    [ "$status" -eq 3 ]
}

@test "healthy host returns OK (0)" {
    PROC_DIR="$FIXTURES/proc-healthy" run "$SCRIPTS/health-check.sh" "${RELAXED_DISK[@]}"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "OK - all checks passed"* ]]
    [[ "$output" == *"memory 50% used"* ]]
}

@test "memory pressure and load return CRITICAL (2)" {
    PROC_DIR="$FIXTURES/proc-stressed" run "$SCRIPTS/health-check.sh" "${RELAXED_DISK[@]}"
    [ "$status" -eq 2 ]
    [[ "${lines[0]}" == CRITICAL* ]]
    [[ "${lines[0]}" == *"memory 97%"* ]]
    [[ "${lines[0]}" == *"load "* ]]
}

@test "memory between warn and crit returns WARNING (1)" {
    PROC_DIR="$FIXTURES/proc-healthy" run "$SCRIPTS/health-check.sh" "${RELAXED_DISK[@]}" --mem-warn 40 --mem-crit 60
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" == "WARNING - memory 50%" ]]
}

@test "missing service returns CRITICAL" {
    command -v systemctl >/dev/null || skip "systemctl not available"
    PROC_DIR="$FIXTURES/proc-healthy" run "$SCRIPTS/health-check.sh" "${RELAXED_DISK[@]}" --service zz-does-not-exist.service
    [ "$status" -eq 2 ]
    [[ "${lines[0]}" == *"zz-does-not-exist.service"* ]]
}
