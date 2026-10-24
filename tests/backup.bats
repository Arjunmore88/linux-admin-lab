#!/usr/bin/env bats
# Tests for scripts/backup.sh. Backups are real but confined to BATS_TEST_TMPDIR.

setup() {
    load test_helper
    SRC="$BATS_TEST_TMPDIR/src"
    DEST="$BATS_TEST_TMPDIR/dest"
    mkdir -p "$SRC/conf.d"
    echo "server_name example.internal;" >"$SRC/conf.d/site.conf"
    echo "hello" >"$SRC/README"
}

@test "--help prints usage and exits 0" {
    run "$SCRIPTS/backup.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--retention"* ]]
}

@test "missing --dest is a usage error" {
    run "$SCRIPTS/backup.sh" --source "$SRC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--dest is required"* ]]
}

@test "non-numeric retention is rejected" {
    run "$SCRIPTS/backup.sh" -s "$SRC" -d "$DEST" -r two-weeks
    [ "$status" -eq 2 ]
}

@test "nonexistent source is rejected" {
    run "$SCRIPTS/backup.sh" -s "$BATS_TEST_TMPDIR/nope" -d "$DEST"
    [ "$status" -eq 2 ]
    [[ "$output" == *"source does not exist"* ]]
}

@test "creates a verified archive with checksum and 0600 permissions" {
    run "$SCRIPTS/backup.sh" -s "$SRC" -d "$DEST" -N cfg
    [ "$status" -eq 0 ]
    archive=$(ls "$DEST"/cfg-*.tar.gz)
    [ -f "$archive.sha256" ]
    [ "$(stat -c %a "$archive")" = "600" ]
    tar -tzf "$archive" | grep -q 'src/conf.d/site.conf'
    run "$SCRIPTS/backup.sh" --verify "$archive"
    [ "$status" -eq 0 ]
}

@test "--verify detects a corrupted archive" {
    "$SCRIPTS/backup.sh" -s "$SRC" -d "$DEST" -N cfg 2>/dev/null
    archive=$(ls "$DEST"/cfg-*.tar.gz)
    printf 'garbage' >>"$archive"
    run "$SCRIPTS/backup.sh" --verify "$archive"
    [ "$status" -eq 1 ]
    [[ "$output" == *"checksum mismatch"* ]]
}

@test "retention prunes old archives of this job only" {
    mkdir -p "$DEST"
    touch -d '20 days ago' "$DEST/cfg-20200101-000000.tar.gz" "$DEST/cfg-20200101-000000.tar.gz.sha256"
    touch -d '20 days ago' "$DEST/other-20200101-000000.tar.gz"
    run "$SCRIPTS/backup.sh" -s "$SRC" -d "$DEST" -N cfg -r 14
    [ "$status" -eq 0 ]
    [ ! -e "$DEST/cfg-20200101-000000.tar.gz" ]
    [ ! -e "$DEST/cfg-20200101-000000.tar.gz.sha256" ]
    [ -e "$DEST/other-20200101-000000.tar.gz" ]
    [ "$(ls "$DEST"/cfg-*.tar.gz | wc -l)" -eq 1 ]
}

@test "--dry-run writes nothing" {
    run "$SCRIPTS/backup.sh" -s "$SRC" -d "$DEST" -N cfg --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$DEST" ]
}
