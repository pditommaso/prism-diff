#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M9 (folder staging and copy).
# Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/M09.sh                 local run (GUI checks when allowed)
#   CI=true scripts/accept/M09.sh         headless only
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh
#   PRISM_ACCEPT_HEADLESS=1     skip the GUI section even when UI scripting works
#
# Safety: every copy runs on scratch copies under a fresh mktemp directory.
# Replaced items go to a trash directory inside it (PrismBench --trash, and
# PRISM_TRASH_DIR for the app), never to the user's Trash.
#
# Mapping of the MILESTONES.md M9 acceptance bullets to sections below:
#   stage docs to the right, copy: right/docs exists, row equal, counts   -> 2a, 3, 4
#   stage src/util/helper.swift to the left: old file trashed, contents   -> 2b, 3, 4
#   cancel a 2 GB copy midway: no partial destination, source untouched   -> 2c, 3
#   read-only destination: recovery dialog, Skip continues                -> 2d, 3, 4
#   undo of a staging choice removes the chevron                         -> 3, 4
#   global definition of done                                            -> 1, 5
#
# The GUI section never brings Prism to the front: the app is opened in the
# background (open -g) with PRISM_TESTING=1, and every step is an AX action
# (AXPress, AXSelected) sent by PID through scripts/accept/tools/axpress.
# It takes the shared GUI lock while Prism runs. The app writes JSON lines
# to PRISM_PERF_LOG (folderLevel, folderStaging, folderCopySummary,
# folderCopy, folderCopyError); the checks read them.
#
# Output of every check: build/accept/M09/checks.log.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M09

SCRATCH="$(mktemp -d)"
readonly SCRATCH
mkdir -p "$SCRATCH/home" "$SCRATCH/out"
: > "$SCRATCH/gitconfig"
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1
m09_cleanup() {
    accept_cleanup
    [[ "${GUI_LOCKED:-0}" == 1 ]] && rm -rf "${GUI_LOCK:-}"
    chmod -R u+w "$SCRATCH" 2>/dev/null
    rm -rf "$SCRATCH"
}
trap m09_cleanup EXIT
trap 'm09_cleanup; exit 130' INT TERM

git_q() {
    HOME="$SCRATCH/home" git "$@"
}

STATUS_BEFORE="$(git_q status --porcelain --untracked-files=all)"

# --- helpers -------------------------------------------------------------------

file_has() {        # file_has <file> <fixed string>...
    local file="$1" s; shift
    [[ -f "$file" ]] || { echo "missing: $file"; return 1; }
    for s in "$@"; do
        grep -Fq -- "$s" "$file" || { echo "$file lacks: $s"; cat "$file"; return 1; }
    done
}

# make_fixture <dir>: the committed folder pair with fixed times (as in M08).
make_fixture() {
    local dir="$1" side
    chmod -R u+w "$dir" 2>/dev/null
    rm -rf "$dir"
    mkdir -p "$dir"
    for side in left right; do
        cp -R "Tests/corpus/fixtures/folders/$side" "$dir/$side" || return 1
        find "$dir/$side" -name .DS_Store -delete
        find "$dir/$side" -depth -exec touch -h -t 202610111446.29 {} + || return 1
        touch -h -t 202001010000.00 "$dir/$side/README.md" || return 1
    done
}

rows_are() {        # rows_are <expected file> <bench args...>
    local expected="$1" out="$SCRATCH/out/rows.txt"; shift
    "$BENCH" folders "$@" > "$out" || return 1
    cat "$out"
    diff -u "$expected" "$out"
}

copy_run() {        # copy_run <output file> <foldercopy args...>
    local out="$1"; shift
    "$BENCH" foldercopy "$@" > "$out" 2>&1
    local s=$?
    cat "$out"
    return $s
}

same_bytes() { cmp "$1" "$2"; }

no_leftovers() {    # no temporary copies below <dir>
    local found
    found=$(find "$1" -name '.prism-copy-*' 2>/dev/null)
    [[ -z "$found" ]] || { echo "left over: $found"; return 1; }
}

dco_check() {
    if git_q rev-parse -q --verify 'master^{commit}' >/dev/null; then
        HOME="$SCRATCH/home" scripts/ci/check-dco.sh master..HEAD
    elif git_q rev-parse -q --verify 'origin/master^{commit}' >/dev/null; then
        HOME="$SCRATCH/home" scripts/ci/check-dco.sh origin/master..HEAD
    else
        echo "notice: no master or origin/master; DCO check skipped here"
    fi
}

changelog_ok() {
    grep -Eiq '^#+ .*m09' CHANGELOG.md && grep -Fq 'Trash' CHANGELOG.md \
        || { echo "CHANGELOG.md has no m09 entry mentioning the Trash"; return 1; }
}

ci_references() {
    file_has .github/workflows/ci.yml scripts/accept/M09.sh build/accept/M09
}

swift_tests() {     # swift_tests <filter> <minimum count>
    local filter="$1" minimum="$2" log="$SCRATCH/out/tests-$RANDOM.log" ran
    swift test --filter "$filter" > "$log" 2>&1
    grep -E '✘|✔ Test run|error:' "$log"
    grep -q '✔ Test run with' "$log" && ! grep -q '✘' "$log" || return 1
    ran=$(grep -oE 'Test run with [0-9]+ test' "$log" | grep -oE '[0-9]+' | head -n 1)
    echo "tests run: ${ran:-0} (want >= $minimum)"
    (( ${ran:-0} >= minimum ))
}

worktree_unchanged() {
    local now
    now="$(git_q status --porcelain --untracked-files=all)"
    [[ "$now" == "$STATUS_BEFORE" ]] || {
        echo "git status changed during the run:"
        diff <(echo "$STATUS_BEFORE") <(echo "$now")
        return 1
    }
}

stat_of() { stat -f '%z %m %i' "$1"; }

# --- 0. build ----------------------------------------------------------------
echo "-- 0. build"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
else
    check "release build zero warnings + swift test (build-strict.sh, logs in build/logs)" scripts/ci/build-strict.sh
fi
check "release build of PrismBench" swift build -c release --product PrismBench
BIN="$(swift build -c release --show-bin-path 2>/dev/null)"
BENCH="$BIN/PrismBench"

# --- 1. definition of done ---------------------------------------------------
echo "-- 1. definition of done"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
check "DCO sign-off (check-dco.sh)" dco_check
check "CHANGELOG.md has an m09 entry" changelog_ok
check "ci.yml runs M09.sh" ci_references

# --- 2. the copy engine on scratch fixtures (headless) --------------------------
echo "-- 2. copy engine"
FIX="$SCRATCH/fixture"
TRASH="$SCRATCH/trash"

# 2a. docs to the right.
check "prepare the fixture pair" make_fixture "$FIX"
check "stage docs to the right and copy: copied, nothing trashed" \
    eval 'copy_run "$SCRATCH/out/2a.txt" --to-right docs --trash "$TRASH" "$FIX/left" "$FIX/right" && file_has "$SCRATCH/out/2a.txt" "staged docs to-right 10 bytes" "copied docs" "outcome copied=1 skipped=0 cancelled=false"'
check "right/docs/guide.md has the left bytes" same_bytes "$FIX/left/docs/guide.md" "$FIX/right/docs/guide.md"
cat > "$SCRATCH/out/2a.expected" <<'EOF'
right-only	-	assets	-	11 bytes
right-only	-	CHANGELOG.md	-	14 bytes
unchanged	docs	docs	10 bytes	10 bytes
left-only	LICENSE	-	13 bytes	-
unchanged	README.md	README.md	5 bytes	5 bytes
changed	src	src	418 bytes	479 bytes
counts changed=1 unchanged=2 unmatched=3
EOF
check "the docs row is now equal; counts 1 Changed, 2 Unchanged, 3 Unmatched" \
    rows_are "$SCRATCH/out/2a.expected" "$FIX/left" "$FIX/right"

# 2b. helper.swift to the left, replacing the old one.
cp "$FIX/left/src/util/helper.swift" "$SCRATCH/out/helper.old"
check "stage src/util/helper.swift to the left (replace) and copy" \
    eval 'copy_run "$SCRATCH/out/2b.txt" --to-left src/util/helper.swift --trash "$TRASH" "$FIX/left" "$FIX/right" && file_has "$SCRATCH/out/2b.txt" "staged src/util/helper.swift to-left replace" "copied src/util/helper.swift" "trashed src/util/helper.swift -> $TRASH/helper.swift"'
check "the old left helper.swift is in the trash, unchanged" same_bytes "$SCRATCH/out/helper.old" "$TRASH/helper.swift"
check "left and right helper.swift now match" same_bytes "$FIX/left/src/util/helper.swift" "$FIX/right/src/util/helper.swift"
cat > "$SCRATCH/out/2b.expected" <<'EOF'
unchanged	helper.swift	helper.swift	16 bytes	16 bytes
counts changed=0 unchanged=1 unmatched=0
EOF
check "the helper.swift row is now equal" rows_are "$SCRATCH/out/2b.expected" --path src/util "$FIX/left" "$FIX/right"
check "no temporary copies left in either root" eval 'no_leftovers "$FIX/left" && no_leftovers "$FIX/right"'

# 2c. a 2 GB copy, cancelled midway.
BIG="$SCRATCH/big"
big_prepare() {
    mkdir -p "$BIG/left" "$BIG/right/keep" || return 1
    mkfile -n 2g "$BIG/left/huge.bin" || return 1
    printf 'old' > "$BIG/right/huge-old.bin"
    mkfile -n 2g "$BIG/left/huge-old.bin" || return 1
    touch -t 202601010000.00 "$BIG/left/huge.bin" "$BIG/left/huge-old.bin"
    stat_of "$BIG/left/huge.bin" > "$SCRATCH/out/huge.stat"
    stat_of "$BIG/left/huge-old.bin" > "$SCRATCH/out/huge-old.stat"
}
big_untouched() {
    [[ "$(stat_of "$BIG/left/huge.bin")" == "$(cat "$SCRATCH/out/huge.stat")" ]] || { echo "huge.bin changed"; return 1; }
    [[ "$(stat_of "$BIG/left/huge-old.bin")" == "$(cat "$SCRATCH/out/huge-old.stat")" ]] || { echo "huge-old.bin changed"; return 1; }
    [[ ! -e "$BIG/right/huge.bin" ]] || { echo "right/huge.bin exists"; return 1; }
    [[ "$(cat "$BIG/right/huge-old.bin")" == old ]] || { echo "right/huge-old.bin was replaced"; return 1; }
    [[ ! -e "$SCRATCH/big-trash" ]] || { echo "something went to the trash"; return 1; }
    no_leftovers "$BIG/right"
}
check "prepare a 2 GB file (and a 2 GB replacement) in a scratch pair" big_prepare
check "cancel the 2 GB copy after 512 MiB: cancelled, nothing copied" \
    eval 'copy_run "$SCRATCH/out/2c.txt" --no-clone --cancel-after-mb 512 --to-right huge.bin --to-right huge-old.bin --trash "$SCRATCH/big-trash" "$BIG/left" "$BIG/right" && file_has "$SCRATCH/out/2c.txt" "cancel at" "not-attempted huge" "outcome copied=0 skipped=0 cancelled=true"'
check "after the cancel: no partial destination, replaced file untouched, sources untouched" big_untouched
check "cancel during the replacement of an existing file keeps the old one" \
    eval 'copy_run "$SCRATCH/out/2c2.txt" --no-clone --cancel-after-mb 256 --to-right huge-old.bin --trash "$SCRATCH/big-trash" "$BIG/left" "$BIG/right" && file_has "$SCRATCH/out/2c2.txt" "cancelled=true" && big_untouched'
chmod -R u+w "$BIG" 2>/dev/null
rm -rf "$BIG"

# 2d. a read-only destination.
check "prepare a fresh fixture pair" make_fixture "$FIX"
chmod 555 "$FIX/right/src/util"
check "read-only right/src/util: the error is reported, Skip goes on with LICENSE" \
    eval 'copy_run "$SCRATCH/out/2d.txt" --on-error retry --to-right src/util/helper.swift --to-right LICENSE --trash "$TRASH" "$FIX/left" "$FIX/right" && file_has "$SCRATCH/out/2d.txt" "error src/util/helper.swift code=13" "Permission denied" "skipped src/util/helper.swift" "copied LICENSE" "outcome copied=1 skipped=1"'
check "the read-only side is untouched; LICENSE arrived" \
    eval 'same_bytes Tests/corpus/fixtures/folders/right/src/util/helper.swift "$FIX/right/src/util/helper.swift" && same_bytes "$FIX/left/LICENSE" "$FIX/right/LICENSE" && no_leftovers "$FIX/right"'
check "Stop ends the copy and leaves the rest" \
    eval 'rm -f "$FIX/right/LICENSE" && copy_run "$SCRATCH/out/2d2.txt" --on-error stop --to-right src/util/helper.swift --to-right LICENSE --trash "$TRASH" "$FIX/left" "$FIX/right" && file_has "$SCRATCH/out/2d2.txt" "not-attempted LICENSE" "stopped=true" && [[ ! -e "$FIX/right/LICENSE" ]]'
chmod 755 "$FIX/right/src/util"

# --- 3. unit tests ---------------------------------------------------------------
echo "-- 3. unit tests"
check "FolderCore staging and copy engine: conflicts, permissions, partial failure, cancel, symlinks, file vs folder, lock, locked items, restore on failure, case/Unicode aliases, parent swapped for a link, stale leftovers" \
    swift_tests 'FolderCoreTests\.(CopyTests|CopySafetyTests|StagingTests)' 32
check "folder window staging and copy: gutter, footer, undo/redo (off while copying), copy, trash, skip, cancel, lock, menu, settings, app-bundle warning, stale cleanup" \
    swift_tests FolderCopyTests 15

# --- 4. GUI ---------------------------------------------------------------------------
PERF="$ACCEPT_DIR/perf.log"
GUI_LOCK="${PRISM_GUI_LOCK:-/private/tmp/claude-501/prism-gui.lock}"
GUI_LOCKED=0
APP_TRASH="$SCRATCH/app-trash"

gui_lock() {
    until mkdir "$GUI_LOCK" 2>/dev/null; do
        if [[ -n "$(find "$GUI_LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]]; then rm -rf "$GUI_LOCK"; continue; fi
        sleep 5
    done
    echo "m09-folder-copy $$" > "$GUI_LOCK/owner"
    GUI_LOCKED=1
}

gui_unlock() {
    (( GUI_LOCKED )) && rm -rf "$GUI_LOCK"
    GUI_LOCKED=0
}

perf_last() {       # perf_last <event> <python expression over d> [filter]
    /usr/bin/python3 -I - "$PERF" "$1" "$2" "${3:-True}" <<'PY'
import json, sys
path, name, expr, cond = sys.argv[1:5]
last = None
try:
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("event") == name and eval(cond, {}, {"d": d}):
            last = d
except OSError:
    pass
if last is not None:
    value = eval(expr, {}, {"d": last})
    print(json.dumps(value) if not isinstance(value, str) else value)
PY
}

perf_true() { [[ -n "$(perf_last "$1" '1' "$2")" ]]; }

# perf_latest_true <event> <condition>: the most recent such event matches
# (perf_true accepts any earlier one, so it cannot tell that an Undo or a
# Redo took effect).
perf_latest_true() { [[ "$(perf_last "$1" "$2")" == true ]]; }

wait_latest() {     # wait_latest <timeout> <event> <condition>
    wait_until "$1" perf_latest_true "$2" "$3" || { echo "the last $2 event does not satisfy $3"; tail -n 5 "$PERF"; return 1; }
}

wait_perf() {       # wait_perf <timeout> <event> <condition>
    wait_until "$1" perf_true "$2" "$3" || { echo "no $2 event with $3"; tail -n 5 "$PERF"; return 1; }
    perf_last "$2" 'd' "$3" | cut -c1-600
}

ax() { accept_tool axpress "$(app_pid)" "$@"; }

# m09_launch <left> <right>: opens Prism in the background (never frontmost).
m09_launch() {
    : > "$PERF"
    if app_pid >/dev/null; then
        echo "an instance of $ACCEPT_APP is already running" >&2
        return 1
    fi
    open -n -g --env "PRISM_PERF_LOG=$PERF" --env PRISM_SHOW_ABOUT=0 --env PRISM_TESTING=1 \
        --env "PRISM_TRASH_DIR=$APP_TRASH" "$ACCEPT_APP" --args "$1" "$2" || return 1
    wait_until 15 app_pid || { echo "Prism did not start" >&2; return 1; }
    ACCEPT_APP_PID=$(app_pid)
    echo "launched pid $ACCEPT_APP_PID: $*"
}

row_index() {       # row_index <name>: index of a row in the last root level
    perf_last folderLevel "[r.split(' | ')[0] or r.split(' | ')[1] for r in d['rows']].index('$1')" "d['path'] == ''"
}

select_row() { ax select prism.folder.tableA "$(row_index "$1")"; }

echo "-- 4. GUI"
if ! gui_available; then
    echo "notice: GUI checks skipped (headless mode)"
else
    check "bundle Prism.app (scripts/bundle.sh)" scripts/bundle.sh
    gui_lock
    make_fixture "$FIX"
    cp "$FIX/left/src/util/helper.swift" "$SCRATCH/out/helper.old"
    check "launch Prism in the background with the fixture folders" m09_launch "$FIX/left" "$FIX/right"
    check "root rows complete: 1 Changed, 1 Unchanged, 4 Unmatched; footer says nothing to copy" \
        wait_perf 15 folderLevel "d['path'] == '' and d['complete'] and d['filterLabels'] == ['1 Changed', '1 Unchanged', '4 Unmatched'] and d['copyStatus'] == 'Nothing to copy'"
    check "select docs, Merge > Copy to Right: chevron staged, '1 file to copy'" \
        eval 'select_row docs && ax menu Merge "Copy to Right" && wait_perf 5 folderStaging "d[\"staged\"] == [\"docs to-right\"] and d[\"copyStatus\"] == \"1 file to copy\""'
    check "the docs gutter button reports the staged direction" \
        eval '[[ "$(ax value prism.folder.stage.docs)" == "Copies to the right" ]]'
    sleep 0.5
    check "capture the staged row (compare with screen 12)" capture folder-staged
    check "Edit > Undo removes the chevron" \
        eval 'ax menu Edit Undo && wait_latest 5 folderStaging "d[\"staged\"] == [] and d[\"copyStatus\"] == \"Nothing to copy\"" && [[ "$(ax value prism.folder.stage.docs)" == "Not staged" ]]'
    check "Edit > Redo brings it back" \
        eval 'ax menu Edit Redo && wait_latest 5 folderStaging "d[\"staged\"] == [\"docs to-right\"] and d[\"copyStatus\"] == \"1 file to copy\""'
    check "Merge > Start Copying Files shows the summary: docs copies to B" \
        eval 'ax menu Merge "Start Copying Files" && wait_perf 5 folderCopySummary "d[\"rows\"] == [\"docs | copies to B\"]"'
    sleep 0.5
    check "capture the summary sheet (compare with screen 13)" capture folder-summary
    check "Copy Files: right/docs exists, the row is equal, counts 1/2/3" \
        eval 'ax id prism.copySummary.copy && wait_perf 10 folderCopy "d[\"phase\"] == \"finished\" and d[\"copied\"] == [\"docs\"]" && wait_perf 10 folderLevel "d[\"path\"] == \"\" and \"docs | docs | unchanged\" in [r.rsplit(\" | \", 1)[0] for r in d[\"rows\"]] and d[\"filterLabels\"] == [\"1 Changed\", \"2 Unchanged\", \"3 Unmatched\"]" && same_bytes "$FIX/left/docs/guide.md" "$FIX/right/docs/guide.md"'
    sleep 0.5
    check "capture after the copy" capture folder-copied
    check "quit Prism" app_quit

    check "launch Prism on src/util of both sides" m09_launch "$FIX/left/src/util" "$FIX/right/src/util"
    check "helper.swift row is changed" wait_perf 15 folderLevel "d['path'] == '' and d['complete'] and d['filterLabels'][0] == '1 Changed'"
    check "the gutter button cycles: right, then left (replace)" \
        eval 'ax id prism.folder.stage.helper.swift && ax id prism.folder.stage.helper.swift && wait_perf 5 folderStaging "d[\"staged\"] == [\"helper.swift to-left replace\"]"'
    check "copy: the old left helper.swift is in the trash and the contents match" \
        eval 'ax menu Merge "Start Copying Files" && wait_perf 5 folderCopySummary "d[\"rows\"] == [\"helper.swift | replaces the one in A\"]" && ax id prism.copySummary.copy && wait_perf 10 folderCopy "d[\"phase\"] == \"finished\" and d[\"copied\"] == [\"helper.swift\"]" && same_bytes "$SCRATCH/out/helper.old" "$APP_TRASH/helper.swift" && same_bytes "$FIX/left/src/util/helper.swift" "$FIX/right/src/util/helper.swift"'
    check "quit Prism" app_quit

    check "launch Prism again on the roots" m09_launch "$FIX/left" "$FIX/right"
    check "rows complete" wait_perf 15 folderLevel "d['path'] == '' and d['complete']"
    chmod 555 "$FIX/right"
    check "read-only right root: LICENSE to the right fails, the recovery sheet appears" \
        eval 'select_row LICENSE && ax menu Merge "Copy to Right" && select_row src && ax menu Merge "Copy to Left" && wait_perf 5 folderStaging "len(d[\"staged\"]) == 2" && ax menu Merge "Start Copying Files" && wait_perf 5 folderCopySummary "len(d[\"rows\"]) == 2" && ax id prism.copySummary.copy && wait_perf 10 folderCopyError "d[\"path\"] == \"LICENSE\" and d[\"code\"] == 13"'
    sleep 0.5
    check "capture the recovery sheet" capture folder-error
    check "Skip continues: src is copied to the left, LICENSE skipped" \
        eval 'ax button Skip && wait_perf 10 folderCopy "d[\"phase\"] == \"finished\" and d[\"skipped\"] == [\"LICENSE\"] and d[\"copied\"] == [\"src\"]"'
    chmod 755 "$FIX/right"
    check "quit Prism" app_quit
    gui_unlock
fi

# --- 5. hygiene -------------------------------------------------------------------------
echo "-- 5. hygiene"
check "git status unchanged by the run" worktree_unchanged

accept_summary
