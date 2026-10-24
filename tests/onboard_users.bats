#!/usr/bin/env bats
# Tests for scripts/onboard-users.sh (non-root safe: validation and dry-run only)

setup() {
    load test_helper
    CSV="$BATS_TEST_TMPDIR/users.csv"
    export SUDOERS_DIR="$BATS_TEST_TMPDIR/sudoers.d"
    mkdir -p "$SUDOERS_DIR"
}

@test "--help prints usage and exits 0" {
    run "$SCRIPTS/onboard-users.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"username,full_name,group,ssh_public_key,sudo,expiry"* ]]
}

@test "missing --csv is a usage error (exit 2)" {
    run "$SCRIPTS/onboard-users.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--csv is required"* ]]
}

@test "unknown argument is a usage error (exit 2)" {
    run "$SCRIPTS/onboard-users.sh" --csv x.csv --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument: --bogus"* ]]
}

@test "shipped configs/users.csv passes validation" {
    run "$SCRIPTS/onboard-users.sh" --csv "$REPO_ROOT/configs/users.csv" --validate-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"CSV is valid"* ]]
}

@test "wrong header is rejected" {
    printf 'user,name\nalice,Alice\n' >"$CSV"
    run "$SCRIPTS/onboard-users.sh" --csv "$CSV" --validate-only
    [ "$status" -eq 2 ]
    [[ "$output" == *"bad header"* ]]
}

@test "all row errors are reported in a single pass" {
    write_csv "$CSV" \
        "Bad User,Bad User,ops,$VALID_KEY,yes," \
        "carol,Carol,ops,not-a-key,yes," \
        "dave,Dave,ops,$VALID_KEY,maybe," \
        "erin,Erin,ops,$VALID_KEY,no,2001-01-01" \
        "frank,Frank,ops,$VALID_KEY,no,2099-13-45"
    run "$SCRIPTS/onboard-users.sh" --csv "$CSV" --validate-only
    [ "$status" -eq 2 ]
    [[ "$output" == *"line 2: invalid username 'Bad User'"* ]]
    [[ "$output" == *"line 3: ssh_public_key is missing"* ]]
    [[ "$output" == *"line 4: sudo must be 'yes' or 'no'"* ]]
    [[ "$output" == *"line 5: expiry 2001-01-01 is in the past"* ]]
    [[ "$output" == *"line 6: expiry '2099-13-45' is not a valid"* ]]
    [[ "$output" == *"failed with 5 error(s)"* ]]
}

@test "duplicate usernames are rejected" {
    write_csv "$CSV" "alice,Alice,ops,$VALID_KEY,no," "alice,Alice Again,ops,$VALID_KEY,no,"
    run "$SCRIPTS/onboard-users.sh" --csv "$CSV" --validate-only
    [ "$status" -eq 2 ]
    [[ "$output" == *"duplicate username 'alice' (first on line 2)"* ]]
}

@test "wrong field count (comma inside a value) is rejected" {
    write_csv "$CSV" "alice,Smith, Alice,ops,$VALID_KEY,no,"
    run "$SCRIPTS/onboard-users.sh" --csv "$CSV" --validate-only
    [ "$status" -eq 2 ]
    [[ "$output" == *"line 2: expected 6 fields, found 7"* ]]
}

@test "comments, blank lines and CRLF line endings are tolerated" {
    printf '# comment\r\n\r\nusername,full_name,group,ssh_public_key,sudo,expiry\r\nalice,Alice,ops,%s,no,2099-01-01\r\n' "$VALID_KEY" >"$CSV"
    run "$SCRIPTS/onboard-users.sh" --csv "$CSV" --validate-only
    [ "$status" -eq 0 ]
}

@test "--dry-run as non-root prints planned actions and changes nothing" {
    [ "$(id -u)" -ne 0 ] || skip "must run as non-root to prove dry-run is side-effect free"
    write_csv "$CSV" "zz-lab-test,Lab Test,zz-lab-grp,$VALID_KEY,yes,2099-01-01"
    run "$SCRIPTS/onboard-users.sh" --csv "$CSV" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] groupadd zz-lab-grp"* ]]
    [[ "$output" == *"[DRY-RUN] useradd -m -s /bin/bash"* ]]
    [[ "$output" == *"[DRY-RUN] chage -E 2099-01-01 zz-lab-test"* ]]
    [[ "$output" == *"90-lab-zz-lab-test"* ]]
    [ ! -e "$SUDOERS_DIR/90-lab-zz-lab-test" ]
    run id zz-lab-test
    [ "$status" -ne 0 ]
}

@test "real run as non-root is refused after validation" {
    [ "$(id -u)" -ne 0 ] || skip "root check cannot be exercised as root"
    run "$SCRIPTS/onboard-users.sh" --csv "$REPO_ROOT/configs/users.csv"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}
