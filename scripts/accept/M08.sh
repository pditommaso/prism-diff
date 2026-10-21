#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M8 (folder comparison, read-only).
# Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/M08.sh                       local run (GUI checks when allowed)
#   CI=true PRISM_PERF_SCALE=3 scripts/accept/M08.sh
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (the release
#                               builds of PrismBench and prism still run)
#   PRISM_PERF_SCALE=<factor>   multiplies the time budgets (default 1)
#   PRISM_PERF_FOLDER_SCAN_SCALE=<factor>
#                               multiplies the deep-pass budget of the 200k
#                               tree instead (default PRISM_PERF_SCALE)
#   PRISM_FOLDER_GEN=<dir>      where the 200k-file tree is generated and
#                               cached (default build/folder-gen)
#
# Mapping of the MILESTONES.md M8 acceptance bullets to sections below:
#   fixture rows, alignment and counts (1/1/4), LICENSE/CHANGELOG unpaired -> 2
#   200k files: first rows <= 50 ms, deep <= 2 s warm, RSS <= 150 MB      -> 3
#   touching a file updates its row in <= 200 ms, no full rescan (log)    -> 4
#   drill-down into src (2 Changed), main.swift text scope (8 changes)    -> 2, 6
#   filters hide and show rows, counts stay correct                      -> 5, 6
#   global definition of done                                            -> 1, 7
#   GUI (screens 10-14): the folder window, filters, drill-down tabs,
#   text tab, live refresh in the window, Settings > Folders, 200k tree
#   responsiveness                                                       -> 6
#
# The GUI section takes the shared GUI lock (/private/tmp/claude-501/
# prism-gui.lock, or PRISM_GUI_LOCK) while Prism.app runs, so that several
# builders never drive the app at the same time. The app writes JSON lines
# to the file named by PRISM_PERF_LOG (events folderLevel, folderFilter,
# folderTabs, folderLog, firstPaint); the checks read them.
#
# Output of every check: build/accept/M08/checks.log.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M08

SCALE="${PRISM_PERF_SCALE:-1}"
SCAN_SCALE="${PRISM_PERF_FOLDER_SCAN_SCALE:-$SCALE}"
readonly SCALE SCAN_SCALE
GEN="${PRISM_FOLDER_GEN:-$ACCEPT_ROOT/build/folder-gen}"
readonly GEN

SCRATCH="$(mktemp -d)"
readonly SCRATCH
mkdir -p "$SCRATCH/home" "$SCRATCH/out"
: > "$SCRATCH/gitconfig"
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1
m08_cleanup() {
    accept_cleanup
    [[ "${GUI_LOCKED:-0}" == 1 ]] && rm -rf "${GUI_LOCK:-}"
    rm -rf "$SCRATCH"
}
trap m08_cleanup EXIT
trap 'm08_cleanup; exit 130' INT TERM

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

# make_fixture <dir>: copies the committed folder pair to <dir>/left and
# <dir>/right with fixed times (git does not keep them): README.md is
# equal on both sides (same bytes, same time), everything else carries one
# 2026 time.
make_fixture() {
    local dir="$1" side
    rm -rf "$dir"
    mkdir -p "$dir"
    for side in left right; do
        cp -R "Tests/corpus/fixtures/folders/$side" "$dir/$side" || return 1
        find "$dir/$side" -name .DS_Store -delete
        find "$dir/$side" -depth -exec touch -h -t 202610111446.29 {} + || return 1
        touch -h -t 202001010000.00 "$dir/$side/README.md" || return 1
    done
}

# rows_are <expected file> <bench args...>: `PrismBench folders` output
# equals the expected text.
rows_are() {
    local expected="$1" out="$SCRATCH/out/rows.txt"; shift
    "$BENCH" folders "$@" > "$out" || return 1
    cat "$out"
    diff -u "$expected" "$out"
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
    grep -Eiq '^#+ .*m08' CHANGELOG.md && grep -Fq 'FolderCore' CHANGELOG.md \
        || { echo "CHANGELOG.md has no m08 entry mentioning FolderCore"; return 1; }
}

ci_references() {
    file_has .github/workflows/ci.yml scripts/accept/M08.sh build/accept/M08
}

# swift_tests <filter> <minimum count>: runs the matching tests; all must
# pass and at least <minimum> must run.
swift_tests() {
    local filter="$1" minimum="$2" log="$SCRATCH/out/tests-$RANDOM.log" ran
    swift test --filter "$filter" > "$log" 2>&1
    grep -E '✘|✔ Test run|error:' "$log"
    grep -q '✔ Test run with' "$log" && ! grep -q '✘' "$log" || return 1
    ran=$(grep -oE 'Test run with [0-9]+ test' "$log" | grep -oE '[0-9]+' | head -n 1)
    echo "tests run: ${ran:-0} (want >= $minimum)"
    (( ${ran:-0} >= minimum ))
}

text_changes() {    # text_changes <a> <b> <count>
    local out="$SCRATCH/out/text.json" s=0
    "$PRISM" diff --json "$1" "$2" > "$out" || s=$?
    (( s == 1 )) || { echo "prism diff exited $s"; return 1; }
    /usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("changes:", d["changes"]); sys.exit(0 if d["changes"] == int(sys.argv[2]) else 1)' "$out" "$3"
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

# --- 0. build ----------------------------------------------------------------
echo "-- 0. build"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
else
    check "release build zero warnings + swift test (build-strict.sh, logs in build/logs)" scripts/ci/build-strict.sh
fi
check "release build of PrismBench and prism" swift build -c release --product PrismBench
check "release build of prism" swift build -c release --product prism
BIN="$(swift build -c release --show-bin-path 2>/dev/null)"
BENCH="$BIN/PrismBench"
PRISM="$BIN/prism"

# --- 1. definition of done ---------------------------------------------------
echo "-- 1. definition of done"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
check "DCO sign-off (check-dco.sh)" dco_check
check "CHANGELOG.md has an m08 entry" changelog_ok
check "ci.yml runs M08.sh" ci_references

# --- 2. fixture comparison -----------------------------------------------------
echo "-- 2. fixture rows"
FIX="$SCRATCH/fixture"
check "prepare the fixture pair with fixed times" make_fixture "$FIX"
cat > "$SCRATCH/out/root.expected" <<'EOF'
right-only	-	assets	-	11 bytes
right-only	-	CHANGELOG.md	-	14 bytes
left-only	docs	-	10 bytes	-
left-only	LICENSE	-	13 bytes	-
unchanged	README.md	README.md	5 bytes	5 bytes
changed	src	src	418 bytes	479 bytes
counts changed=1 unchanged=1 unmatched=4
EOF
check "root rows, alignment and counts: 1 Changed, 1 Unchanged, 4 Unmatched; LICENSE and CHANGELOG.md unpaired" \
    rows_are "$SCRATCH/out/root.expected" "$FIX/left" "$FIX/right"
cat > "$SCRATCH/out/src.expected" <<'EOF'
changed	main.swift	main.swift	407 bytes	463 bytes
changed	util	util	11 bytes	16 bytes
counts changed=2 unchanged=0 unmatched=0
EOF
check "drill-down into src: 2 Changed" rows_are "$SCRATCH/out/src.expected" --path src "$FIX/left" "$FIX/right"
check "the same rows with the fts fallback" rows_are "$SCRATCH/out/root.expected" --method fts "$FIX/left" "$FIX/right"
check "src/main.swift pair has 8 text changes" text_changes "$FIX/left/src/main.swift" "$FIX/right/src/main.swift" 8

# --- 3. 200k-file tree -----------------------------------------------------------
echo "-- 3. generated tree (scale $SCALE)"
check "generate (or reuse) 200k files in 20k folders under ${GEN#"$ACCEPT_ROOT/"}" "$BENCH" foldergen "$GEN"
check "first rows <= 50 ms, deep pass <= 2 s warm, RSS <= 150 MB, root counts 14/6/1" \
    "$BENCH" folderperf --first-rows-ms "$(perl -e "print 50 * $SCALE")" --deep-ms "$(perl -e "print 2000 * $SCAN_SCALE")" \
        --expect 14,6,1 "$GEN/left" "$GEN/right"
check "fts fallback finds the same root counts" \
    "$BENCH" folderperf --method fts --runs 1 --deep-ms 10000 --scale "$SCALE" --expect 14,6,1 "$GEN/left" "$GEN/right"

# --- 4. live refresh -----------------------------------------------------------------
echo "-- 4. live refresh"
DEEP_FILE=$(cd "$GEN/right" && find top03 -type f -name 'file*' | sort | head -n 1)
check "touch in the 200k tree ($DEEP_FILE): row updated <= 200 ms, no full rescan (log)" \
    "$BENCH" folderwatch --budget-ms "$(perl -e "print 200 * $SCALE")" --touch "$DEEP_FILE" "$GEN/left" "$GEN/right"
check "touch src/main.swift in the fixture: row updated <= 200 ms, no full rescan (log)" \
    "$BENCH" folderwatch --budget-ms "$(perl -e "print 200 * $SCALE")" --touch src/main.swift "$FIX/left" "$FIX/right"

# --- 5. engine tests -------------------------------------------------------------------
echo "-- 5. engine tests"
check "FolderCore tests: pairing, filters, counts, sorting, scan rules, digest, live refresh" \
    swift_tests FolderCoreTests 29
check "folder window tests: aligned rows, filters, shared selection, drill-down tabs, text tab with 8 changes" \
    swift_tests FolderViewTests 5

# --- 6. GUI ---------------------------------------------------------------------------
PERF="$ACCEPT_DIR/perf.log"
GUI_LOCK="${PRISM_GUI_LOCK:-/private/tmp/claude-501/prism-gui.lock}"
GUI_LOCKED=0

gui_lock() {
    until mkdir "$GUI_LOCK" 2>/dev/null; do
        if [[ -n "$(find "$GUI_LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]]; then rm -rf "$GUI_LOCK"; continue; fi
        sleep 5
    done
    echo "m08-folder-view $$" > "$GUI_LOCK/owner"
    GUI_LOCKED=1
}

gui_unlock() {
    (( GUI_LOCKED )) && rm -rf "$GUI_LOCK"
    GUI_LOCKED=0
}

# perf_last <event> <python expression over d> [python filter over d]:
# the expression for the last matching event (empty when none).
perf_last() {
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

perf_true() {       # perf_true <event> <condition>: the last matching event exists
    [[ -n "$(perf_last "$1" '1' "$2")" ]]
}

wait_perf() {       # wait_perf <timeout> <event> <condition>
    wait_until "$1" perf_true "$2" "$3" || { echo "no $2 event with $3"; tail -n 5 "$PERF"; return 1; }
    perf_last "$2" 'd' "$3" | cut -c1-600
}

m08_launch() {      # m08_launch <app arguments...>
    : > "$PERF"
    if app_pid >/dev/null; then
        echo "an instance of $ACCEPT_APP is already running" >&2
        return 1
    fi
    open -n --env "PRISM_PERF_LOG=$PERF" --env PRISM_SHOW_ABOUT=0 "$ACCEPT_APP" --args "$@" || return 1
    wait_until 15 app_pid || { echo "Prism did not start" >&2; return 1; }
    ACCEPT_APP_PID=$(app_pid)
    echo "launched pid $ACCEPT_APP_PID: $*"
}

ax_click_checkbox() {   # ax_click_checkbox <title>
    _ax "click checkbox $(_as_string "$1") of window 1" >/dev/null
}

type_and_open() {       # type_and_open <key code>: type-select a row, then Return
    app_key "$1" && sleep 0.4 && app_key 36
}

# touch_latency <file> <level path> <row name>: touches the file and waits
# for the window's row to show the new time; the delay must be within
# 200 ms x scale, and the log must show no second full scan.
touch_latency() {
    local file="$1" path="$2" name="$3" t0 ms budget
    budget=$(perl -e "print 200 * $SCALE")
    t0=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
    touch "$file" || return 1
    wait_perf 5 folderLevel "d['path'] == '$path' and d['wallMs'] >= $t0 and any(r.startswith('$name |') and int(r.split(' | ')[3]) // 10**9 >= $t0 // 1000 - 1 for r in d['rows'])" >/dev/null || return 1
    ms=$(perf_last folderLevel "int(d['wallMs']) - $t0" "d['path'] == '$path' and d['wallMs'] >= $t0")
    echo "row updated $ms ms after the touch (budget $budget ms)"
    perf_last folderLog 'd["line"]' "'incremental refresh' in d['line']"
    local full
    full=$(grep -c 'full scan started' "$PERF")
    echo "full scans in the log: $full"
    (( ms <= budget )) && (( full == 1 ))
}

settings_open() { [[ "$(_ax 'return exists window "Settings"')" == true ]]; }

settings_has_folders_pane() {
    ax_click_menu Prism "Settings…" || return 1
    wait_until 5 settings_open || { echo "no Settings window"; return 1; }
    _ax 'click button "Folders" of toolbar 1 of window "Settings"' >/dev/null || return 1
    sleep 0.5
    local names
    names=$(_ax 'set AppleScript'"'"'s text item delimiters to ", "' \
        'return (name of every checkbox of group 1 of window "Settings") as text') || return 1
    echo "checkboxes: $names"
    _ax 'click button 1 of window "Settings"' >/dev/null || true
    [[ "$names" == *"Show hidden files"* && "$names" == *"Compare file contents"* ]]
}

echo "-- 6. GUI"
if ! gui_available; then
    echo "notice: GUI checks skipped (headless mode)"
else
    check "bundle Prism.app (scripts/bundle.sh)" scripts/bundle.sh
    gui_lock
    make_fixture "$FIX"
    check "launch Prism with the two fixture folders" m08_launch "$FIX/left" "$FIX/right"
    check "folder window: tab 'left | right'" wait_perf 15 folderTabs "d['titles'] == ['left | right']"
    check "root rows complete: 1 Changed, 1 Unchanged, 4 Unmatched, aligned, LICENSE/CHANGELOG.md unpaired" \
        wait_perf 15 folderLevel "d['path'] == '' and d['complete'] and d['filterLabels'] == ['1 Changed', '1 Unchanged', '4 Unmatched'] and [r.rsplit(' | ', 1)[0] if r.count(' | ') == 3 else r for r in d['rows']] == [' | assets | right-only', ' | CHANGELOG.md | right-only', 'docs |  | left-only', 'LICENSE |  | left-only', 'README.md | README.md | unchanged', 'src | src | changed']"
    sleep 0.5
    check "capture the folder window (compare with screen 10)" capture folder-root
    check "filter: uncheck 4 Unmatched hides 4 rows, counts unchanged" \
        eval 'ax_click_checkbox "4 Unmatched" && wait_perf 5 folderFilter "d[\"visibleRows\"] == 2 and d[\"filterLabels\"] == [\"1 Changed\", \"1 Unchanged\", \"4 Unmatched\"]"'
    check "filter: uncheck 1 Unchanged leaves the changed row" \
        eval 'ax_click_checkbox "1 Unchanged" && wait_perf 5 folderFilter "d[\"visibleRows\"] == 1 and d[\"rows\"][0].startswith(\"src | src | changed\")"'
    check "capture with only changed rows" capture folder-filtered
    check "filter: checking both again shows all 6 rows" \
        eval 'ax_click_checkbox "4 Unmatched" && ax_click_checkbox "1 Unchanged" && wait_perf 5 folderFilter "d[\"visibleRows\"] == 6"'
    check "drill-down: select src, Return opens tab 'src (left) | src (right)'" \
        eval 'type_and_open 1 && wait_perf 5 folderTabs "d[\"titles\"] == [\"left | right\", \"src (left) | src (right)\"] and d[\"selected\"] == 1"'
    check "src level shows 2 Changed" \
        wait_perf 10 folderLevel "d['path'] == 'src' and d['complete'] and d['filterLabels'] == ['2 Changed', '0 Unchanged', '0 Unmatched']"
    sleep 0.5
    check "capture the src tab (compare with screen 14)" capture folder-src
    check "touching right/src/main.swift updates its row in the window <= 200 ms, no full rescan (log)" \
        touch_latency "$FIX/right/src/main.swift" src main.swift
    check "open main.swift: text tab with 8 changes" \
        eval 'type_and_open 46 && wait_perf 10 folderTabs "len(d[\"titles\"]) == 3 and d[\"titles\"][2] == \"main.swift (left) | main.swift (right)\"" && wait_perf 10 firstPaint "d[\"changes\"] == 8"'
    sleep 0.5
    check "capture the text tab" capture folder-text
    check "Cmd-W closes the text tab, the window stays" \
        eval 'app_key 13 cmd && wait_perf 5 folderTabs "len(d[\"titles\"]) == 2" && app_running'
    check "Settings has a Folders pane with Show hidden files and Compare file contents" settings_has_folders_pane
    check "quit Prism" app_quit

    check "launch Prism with the 200k-file trees" m08_launch "$GEN/left" "$GEN/right"
    check "200k: first rows in the window <= 50 ms after it opens" \
        wait_perf 15 folderLevel "d['path'] == '' and d['generation'] == 1 and d['sinceOpenMs'] <= 50 * $SCALE"
    check "200k: complete, root counts 14/6/1, main thread never blocked > 100 ms, RSS <= 250 MB" \
        wait_perf 30 folderLevel "d['path'] == '' and d['complete'] and d['filterLabels'] == ['14 Changed', '6 Unchanged', '1 Unmatched'] and d['longestMainThreadGapMs'] <= 100 * $SCALE and d['rssMB'] <= 250"
    sleep 0.5
    check "capture the 200k comparison" capture folder-200k
    check "quit Prism" app_quit
    gui_unlock
fi

# --- 7. hygiene -------------------------------------------------------------------------
echo "-- 7. hygiene"
check "git status unchanged by the run" worktree_unchanged

accept_summary
