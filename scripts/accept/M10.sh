#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M10 (tabs, file shelf, launch window,
# menus, state restoration).
# Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/M10.sh                 local run (GUI checks when allowed)
#   CI=true scripts/accept/M10.sh         headless only
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh
#   PRISM_ACCEPT_HEADLESS=1     skip the GUI section even when UI scripting works
#   PRISM_REFERENCE_MENUS=<dir> folder with the reference menu listings
#                               (menus-text-2up.txt, menus-folder.txt); read
#                               in place, never copied into the repository.
#                               Without it the menu comparison is skipped
#                               (the listings are still produced and checked).
#
# Mapping of the MILESTONES.md M10 acceptance bullets to sections below:
#   every menu item, shortcut and enabled state of the text and folder
#   reference menus (AX listing diff: product name and Help only)       -> 2, 3, 5c
#   (the 3-way merge context comes with the merge scope, M7)
#   shelf with 4 files: -> cycles B in order, the comparison updates     -> 2, 5b
#   quit with 3 tabs, relaunch: 3 tabs with their view modes             -> 2, 5d
#   drag a tab out: new window with it, the source keeps the rest        -> 2, 5d
#   launch window, shelf, multi-tab strip vs screens 30, 07, 14 (visual) -> 5a, 5b, 5d
#   global definition of done                                            -> 1, 6
#
# Intended deviations, which the comparison (tools/menucompare.py) sets
# aside:
#   - Registration… and Check for Updates… are left out: an open-source
#     app has no licence to register and no update service.
#   - File > Save is disabled while nothing is unsaved (M6 rule); the
#     reference keeps it enabled. Its enabled state is not compared.
#   - In the GUI run, Paste and Paste to Comparison depend on what the
#     user's clipboard holds, and Return is bound to Open Selection only
#     while the window is key (the app stays in the background): their
#     state or shortcut is not compared there. The headless listings fix
#     the clipboard and compare them fully.
#
# The GUI section never brings Prism to the front: the app opens in the
# background (open -g) with PRISM_TESTING=1, every step is an AX action
# sent by PID (scripts/accept/tools/axpress), and the menus are read
# through AX attributes (scripts/accept/tools/axmenu). It takes the shared
# GUI lock while Prism runs. Window state goes to a scratch file
# (PRISM_STATE_PATH, also set by lib.sh), never to the user's: under
# PRISM_TESTING=1 the app has no state file unless that variable names one.
#
# Output of every check: build/accept/M10/checks.log.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M10

SCRATCH="$(mktemp -d)"
readonly SCRATCH
mkdir -p "$SCRATCH/home" "$SCRATCH/out"
: > "$SCRATCH/gitconfig"
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1
m10_cleanup() {
    accept_cleanup
    [[ "${GUI_LOCKED:-0}" == 1 ]] && rm -rf "${GUI_LOCK:-}"
    rm -rf "$SCRATCH"
}
trap m10_cleanup EXIT
trap 'm10_cleanup; exit 130' INT TERM

git_q() {
    HOME="$SCRATCH/home" git "$@"
}

STATUS_BEFORE="$(git_q status --porcelain --untracked-files=all)"
REFERENCE="${PRISM_REFERENCE_MENUS:-}"
MENUS="$ACCEPT_DIR/menus"
rm -rf "$MENUS"
mkdir -p "$MENUS"

# --- helpers -------------------------------------------------------------------

file_has() {        # file_has <file> <fixed string>...
    local file="$1" s; shift
    [[ -f "$file" ]] || { echo "missing: $file"; return 1; }
    for s in "$@"; do
        grep -Fq -- "$s" "$file" || { echo "$file lacks: $s"; return 1; }
    done
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
    grep -Eiq '^#+ .*m10' CHANGELOG.md || { echo "CHANGELOG.md has no m10 entry"; return 1; }
}

ci_references() {
    file_has .github/workflows/ci.yml scripts/accept/M10.sh build/accept/M10
}

# swift_tests <filter> <minimum count>: runs the matching tests; all must
# pass and at least <minimum> must run.
swift_tests() {
    local filter="$1" minimum="$2" log="$SCRATCH/out/tests-$RANDOM.log" ran
    PRISM_MENU_DUMP_DIR="$MENUS" swift test --filter "$filter" > "$log" 2>&1
    grep -E '✘|✔ Test run|error:' "$log"
    grep -q '✔ Test run with' "$log" && ! grep -q '✘' "$log" || return 1
    ran=$(grep -oE 'Test run with [0-9]+ test' "$log" | grep -oE '[0-9]+' | head -n 1)
    echo "tests run: ${ran:-0} (want >= $minimum)"
    (( ${ran:-0} >= minimum ))
}

# menus_match <context> <listing> [extra menucompare options]: the listing
# matches the reference one, Help and the product name aside.
menus_match() {
    local context="$1" listing="$2"; shift 2
    [[ -s "$listing" ]] || { echo "no listing $listing"; return 1; }
    /usr/bin/python3 -I scripts/accept/tools/menucompare.py --ignore-state Save "$@" \
        "$REFERENCE/menus-$context.txt" "$listing"
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

tool_builds() {     # tool_builds <name>: the accept tool compiles
    local out="$SCRATCH/out/$1"
    swiftc -O -swift-version 6 -o "$out" "scripts/accept/tools/$1.swift" 2>&1 | grep -v "ld: warning: search path" || true
    [[ -x "$out" ]]
}

# --- 0. build ------------------------------------------------------------------
echo "-- 0. build"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
else
    check "release build zero warnings + swift test (build-strict.sh, logs in build/logs)" scripts/ci/build-strict.sh
fi

# --- 1. definition of done -------------------------------------------------------
echo "-- 1. definition of done"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
check "DCO sign-off (check-dco.sh)" dco_check
check "CHANGELOG.md has an m10 entry" changelog_ok
check "ci.yml runs M10.sh" ci_references

# --- 2. shell tests ------------------------------------------------------------
echo "-- 2. tests"
check "shell tests: shelf (4 files, -> cycles B, comparison updates), tabs (select, reorder, Cmd-W, drag out), launch window, paste, restoration (3 tabs + modes), recent, breadcrumbs, menus" \
    swift_tests ShellTests 18
check "earlier window tests still pass (folder tabs, text tabs of folders, changesets, menus)" \
    swift_tests 'FolderViewTests|EditingRegressionTests|ChangesetTests|PrismAppMainTests|FolderCopyTests' 30

# --- 3. menus against the reference ---------------------------------------------
echo "-- 3. menus"
listings_written() {
    file_has "$MENUS/menus-text-2up.txt" "## View" "- Fluid [0:2:50] ✓" \
        && file_has "$MENUS/menus-folder.txt" "- Open Selection"
}
check "menu listings were written for the text and folder contexts" listings_written
if [[ -n "$REFERENCE" && -f "$REFERENCE/menus-text-2up.txt" && -f "$REFERENCE/menus-folder.txt" ]]; then
    check "text 2-up: every item, shortcut and enabled state matches the reference (Help, product name aside)" \
        menus_match text-2up "$MENUS/menus-text-2up.txt"
    check "folder: every item, shortcut and enabled state matches the reference (Help, product name aside)" \
        menus_match folder "$MENUS/menus-folder.txt"
else
    echo "notice: PRISM_REFERENCE_MENUS not set (or incomplete); comparison with the reference skipped"
fi
echo "notice: the 3-way merge context (menus-merge-3up) is checked with the merge scope (M7)"

# --- 4. tools --------------------------------------------------------------------
echo "-- 4. tools"
check "axmenu (AX menu listing) compiles" tool_builds axmenu
check "axpress (AX actions, custom actions) compiles" tool_builds axpress

# --- 5. GUI ------------------------------------------------------------------------
PERF="$ACCEPT_DIR/perf.log"
STATE="$SCRATCH/state.json"
GUI_LOCK="${PRISM_GUI_LOCK:-/private/tmp/claude-501/prism-gui.lock}"
GUI_LOCKED=0
TEXT="$ACCEPT_ROOT/Tests/corpus/fixtures/text"

gui_lock() {
    until mkdir "$GUI_LOCK" 2>/dev/null; do
        if [[ -n "$(find "$GUI_LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]]; then rm -rf "$GUI_LOCK"; continue; fi
        sleep 5
    done
    echo "m10-shell $$" > "$GUI_LOCK/owner"
    GUI_LOCKED=1
}

gui_unlock() {
    (( GUI_LOCKED )) && rm -rf "$GUI_LOCK"
    GUI_LOCKED=0
}

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

perf_true() { [[ -n "$(perf_last "$1" '1' "$2")" ]]; }

wait_perf() {       # wait_perf <timeout> <event> <condition>
    wait_until "$1" perf_true "$2" "$3" || { echo "no $2 event with $3"; tail -n 5 "$PERF"; return 1; }
    perf_last "$2" 'd' "$3" | cut -c1-600
}

ax() { accept_tool axpress "$(app_pid)" "$@"; }

# m10_launch [VAR=value...] -- [arguments...]: opens Prism in the background.
m10_launch() {
    local envs=(--env "PRISM_PERF_LOG=$PERF" --env PRISM_TESTING=1 --env "PRISM_STATE_PATH=$STATE")
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=(--env "$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    : > "$PERF"
    if app_pid >/dev/null; then
        echo "an instance of $ACCEPT_APP is already running" >&2
        return 1
    fi
    open -n -g "${envs[@]}" "$ACCEPT_APP" --args "$@" || return 1
    wait_until 15 app_pid || { echo "Prism did not start" >&2; return 1; }
    ACCEPT_APP_PID=$(app_pid)
    echo "launched pid $ACCEPT_APP_PID: $*"
}

window_size_is() {  # window_size_is <width> <height>: our only normal window has that content size (+ up to 40 for the title bar)
    local lines w h
    lines=$(_app_windows | awk -F'\t' '$2 == 0')
    echo "${lines:-<no layer-0 windows>}"
    (( $(grep -c . <<<"$lines") == 1 )) || { echo "want exactly 1 window"; return 1; }
    IFS=, read -r _ _ w h <<<"$(cut -f3 <<<"$lines")"
    (( w == $1 && h >= $2 && h <= $2 + 40 ))
}

window_count() {    # window_count <n>: our app shows n normal windows
    local n
    n=$(_app_windows | awk -F'\t' '$2 == 0' | grep -c .)
    echo "normal windows: $n"
    (( n == $1 ))
}

ax_menus() {        # ax_menus <file>: the app's menu bar as AX lists it
    "$SCRATCH/out/axmenu" "$(app_pid)" > "$1" && [[ -s "$1" ]]
}

make_folders() {    # make_folders <dir>: the folder fixture with fixed times
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

shelf_b_is() {      # shelf_b_is <index> <file name>: after "›", B is that file and it is drawn
    ax id prism.shelf.next || return 1
    wait_perf 5 shelf "d['b'] == $1 and d['title'].endswith('$2')" >/dev/null || return 1
    wait_perf 10 firstPaint "True" >/dev/null
}

echo "-- 5. GUI"
if ! gui_available; then
    echo "notice: GUI checks skipped (headless mode)"
else
    check "bundle Prism.app (scripts/bundle.sh)" scripts/bundle.sh
    gui_lock
    FIX="$SCRATCH/folders"
    make_folders "$FIX"
    for n in 0 1 2 3; do
        printf 'one\ntwo %s\nthree\n' "$n" > "$SCRATCH/out/shelf$n.txt"
    done

    # 5a. launch window (screen 30)
    check "plain launch: the launch window, 400x500, no tab strip" \
        eval 'm10_launch -- && wait_perf 10 windowTabs "d[\"launchMode\"] and d[\"scopes\"] == [\"empty\"]" && window_size_is 400 500'
    sleep 0.5
    check "capture the launch window (compare with screen 30)" capture launch-window
    check "quit Prism" app_quit

    # 5b. shelf (screen 07)
    check "launch with 4 files: one comparison, the shelf shows 4 cards" \
        eval 'm10_launch -- "$SCRATCH"/out/shelf{0,1,2,3}.txt && wait_perf 10 shelf "d[\"visible\"] and len(d[\"files\"]) == 4 and d[\"a\"] == 0 and d[\"b\"] == 1"'
    sleep 0.5
    check "capture the shelf (compare with screen 07)" capture shelf
    check "› cycles B: shelf2, shelf3, then shelf1 (A skipped); the comparison follows" \
        eval 'shelf_b_is 2 shelf2.txt && shelf_b_is 3 shelf3.txt && shelf_b_is 1 shelf1.txt'
    check "quit Prism" app_quit

    # 5c. menus as AX reports them
    check "launch a.swift b.swift in Fluid, select the first change (an insert)" \
        eval 'm10_launch -- -prism.text.viewMode fluid "$TEXT/a.swift" "$TEXT/b.swift" && wait_perf 10 firstPaint "d[\"mode\"] == \"fluid\"" && ax menu View "Next Change" && wait_perf 5 selection "d.get(\"change\") == 1"'
    check "AX menu listing (text)" ax_menus "$MENUS/ax-text-2up.txt"
    if [[ -n "$REFERENCE" && -f "$REFERENCE/menus-text-2up.txt" ]]; then
        check "text 2-up AX menus match the reference (Help, product name aside; clipboard-dependent Paste ignored)" \
            menus_match text-2up "$MENUS/ax-text-2up.txt" --ignore-state Paste --ignore-state "Paste to Comparison"
    fi
    check "quit Prism" app_quit
    # Return is bound to Open Selection only while the window is key; the
    # app stays in the background here, so that shortcut is not compared.
    check "launch the folder fixture, select README.md" \
        eval 'm10_launch -- "$FIX/left" "$FIX/right" && wait_perf 15 folderLevel "d[\"path\"] == \"\" and d[\"complete\"]" && ax select prism.folder.tableA 4'
    check "AX menu listing (folder)" ax_menus "$MENUS/ax-folder.txt"
    if [[ -n "$REFERENCE" && -f "$REFERENCE/menus-folder.txt" ]]; then
        check "folder AX menus match the reference (Help, product name aside)" \
            menus_match folder "$MENUS/ax-folder.txt" --ignore-key "Open Selection"
    fi
    check "quit Prism" app_quit

    # 5d. tabs, restoration, drag out (screen 14)
    TABS="$TEXT/a.swift|$TEXT/b.swift;$SCRATCH/out/shelf0.txt|$SCRATCH/out/shelf1.txt;$SCRATCH/out/shelf2.txt|$SCRATCH/out/shelf3.txt"
    rm -f "$STATE"
    check "launch with 3 tabs in one window" \
        eval 'm10_launch "PRISM_DEBUG_OPEN_TABS=$TABS" -- && wait_perf 10 windowTabs "len(d[\"titles\"]) == 3"'
    check "tab 0 Blocks, tab 1 Fluid, tab 2 Unified (AX press on the tabs, View menu)" \
        eval 'ax id prism.tab.0 && ax menu View Blocks && ax id prism.tab.1 && ax menu View Fluid && ax id prism.tab.2 && ax menu View Unified && wait_perf 5 windowTabs "d[\"modes\"] == [\"blocks\", \"fluid\", \"unified\"]"'
    check "Window > Select Next Tab wraps to the first tab" \
        eval 'ax menu Window "Select Next Tab" && wait_perf 5 windowTabs "d[\"selected\"] == 0"'
    sleep 0.5
    check "capture the 3-tab strip (compare with screen 14)" capture tabs
    check "Prism > Quit and Keep Windows saves the 3 tabs" \
        eval 'ax menu Prism "Quit and Keep Windows" && wait_until 10 eval "! app_running" && file_has "$STATE" "\"mode\" : \"unified\""'
    ACCEPT_APP_PID=""
    check "relaunch: the 3 tabs come back with their view modes" \
        eval 'm10_launch -- && wait_perf 10 stateRestored "d[\"windows\"] == 1" && wait_perf 10 windowTabs "len(d[\"titles\"]) == 3 and d[\"modes\"] == [\"blocks\", \"fluid\", \"unified\"]"'
    check "drag tab 2 out (AX: Move Tab to New Window): a new window with it, the source keeps 2" \
        eval 'ax action prism.tab.2 "Move Tab to New Window" && wait_perf 5 tabDetached "len(d[\"remaining\"]) == 2" && wait_until 5 window_count 2'
    check "quit Prism" app_quit
    gui_unlock
fi

# --- 6. hygiene -------------------------------------------------------------------------
echo "-- 6. hygiene"
check "git status unchanged by the run" worktree_unchanged

accept_summary
