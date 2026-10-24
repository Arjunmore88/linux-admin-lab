#!/usr/bin/env bats
# Tests for scripts/lib/common.sh

setup() {
    load test_helper
}

@test "detect_distro: Ubuntu maps to debian family" {
    run bash -c 'source "$SCRIPTS/lib/common.sh"; OS_RELEASE_FILE="$FIXTURES/os-release-ubuntu"; detect_distro; echo "$DISTRO_ID $DISTRO_FAMILY"'
    [ "$status" -eq 0 ]
    [ "$output" = "ubuntu debian" ]
}

@test "detect_distro: Rocky maps to rhel family" {
    run bash -c 'source "$SCRIPTS/lib/common.sh"; OS_RELEASE_FILE="$FIXTURES/os-release-rocky"; detect_distro; echo "$DISTRO_ID $DISTRO_FAMILY"'
    [ "$status" -eq 0 ]
    [ "$output" = "rocky rhel" ]
}

@test "detect_distro: unsupported distro fails clearly" {
    run bash -c 'source "$SCRIPTS/lib/common.sh"; OS_RELEASE_FILE="$FIXTURES/os-release-arch"; detect_distro'
    [ "$status" -eq 1 ]
    [[ "$output" == *"unsupported distribution: ID=arch"* ]]
}

@test "run: prints instead of executing in dry-run mode" {
    marker="$BATS_TEST_TMPDIR/should-not-exist"
    run bash -c "source \"\$SCRIPTS/lib/common.sh\"; DRY_RUN=1; run touch '$marker'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] touch"* ]]
    [ ! -e "$marker" ]
}

@test "is_valid_username: accepts and rejects the right names" {
    run bash -c 'source "$SCRIPTS/lib/common.sh"
        for u in alice svc_backup a-b _x; do is_valid_username "$u" || exit 1; done
        for u in Alice 1abc "a b" "" "$(printf "a%.0s" {1..40})"; do is_valid_username "$u" && exit 2; done
        exit 0'
    [ "$status" -eq 0 ]
}
