#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M6 (editing, two-way merge actions,
# undo and saving). Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/M06.sh             local run; adds the GUI section when
#                                     Accessibility is granted
#   CI=true scripts/accept/M06.sh     headless: never launches the app
#
# Headless checks run the model and controller layer in the unit tests
# (no window is ever shown) and compare the files they save byte for byte.
# The GUI section drives build/Prism.app only through AXPress on menu items
# (never key presses, never bringing Prism to the front) with
# PRISM_TESTING=1, so it can run while the user works.
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (the app's
#                               unit tests still run)
#   PRISM_PERF_SCALE=<factor>   multiplies the time budgets (default 1)
#   PRISM_ACCEPT_HEADLESS=1     force headless mode locally
#
# Mapping of the MILESTONES.md M6 acceptance bullets to sections below:
#   a.swift/b.swift: change 2, Cmd-Right: B line 4 = A line 3;   -> 3 (unit) and 7 (GUI, menus)
#     Undo restores it, Redo re-applies it
#   every change copied left to right and saved: B == A bytes     -> 3 (unit + cmp) and 7 (GUI)
#   UTF-16LE CRLF edited and saved round-trips (hex compare)      -> 4
#   editing a line of big_b re-diffs and repaints in <= 150 ms,   -> 5 (release build)
#     alignment holds
#   merging into a $TMPDIR snapshot shows the guard, no change    -> 6 (unit) and 7 (GUI)
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M06

readonly TEXT="$ACCEPT_ROOT/Tests/corpus/fixtures/text"
SCALE="${PRISM_PERF_SCALE:-1}"
readonly SCALE
readonly OUT="$ACCEPT_DIR/out"
readonly SHOTS="$ACCEPT_DIR/shots"
readonly WORK="$ACCEPT_DIR/work"
readonly PERF="$ACCEPT_DIR/perf.log"
rm -rf "$OUT" "$SHOTS" "$WORK"
mkdir -p "$OUT" "$SHOTS" "$WORK"

budget() { /usr/bin/python3 -I -c "print($1 * $SCALE)"; }

# unit <filter>: runs the app's unit tests matching the filter, leaving the
# files they save in $OUT and their offscreen renders in $SHOTS.
unit() {
    PRISM_M06_OUT="$OUT" PRISM_M06_SHOTS="$SHOTS" swift test --filter "$1" 2>&1 \
        | grep -v "search path" | tee -a "$ACCEPT_DIR/unit.log" | grep -E "✔|✘|passed|failed|error" | tail -n 40
    return "${PIPESTATUS[0]}"
}

same_bytes() {
    cmp "$1" "$2" && echo "identical: ${1#"$ACCEPT_ROOT/"} == ${2#"$ACCEPT_ROOT/"}"
}

# hex_equal <file> <expected>: the hex dumps match; prints both heads.
hex_equal() {
    echo "saved:    $(xxd -p "$1" | tr -d '\n' | cut -c1-96)"
    echo "expected: $(xxd -p "$2" | tr -d '\n' | cut -c1-96)"
    [[ "$(xxd -p "$1")" == "$(xxd -p "$2")" ]]
}

# utf16_crlf <file>: starts with the UTF-16LE BOM and every newline is CR LF.
utf16_crlf() {
    /usr/bin/python3 -I - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert data[:2] == b"\xff\xfe", "no UTF-16LE BOM"
text = data[2:].decode("utf-16-le")
lines = text.count("\n")
assert lines > 0 and text.count("\r\n") == lines and text.count("\r") == lines, "line endings changed"
print(f"utf-16le with BOM, {lines} CRLF lines")
PY
}

# --- 1. guards ---------------------------------------------------------------------
echo "-- 1. guards"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
if git rev-parse -q --verify 'master^{commit}' >/dev/null; then
    check "DCO sign-off (check-dco.sh master..HEAD)" scripts/ci/check-dco.sh master..HEAD
fi

# --- 2. build and tests --------------------------------------------------------------
echo "-- 2. build and tests"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
    check "app unit tests" swift test --filter PrismAppTests
else
    check "release build zero warnings + swift test (build-strict.sh)" scripts/ci/build-strict.sh
fi

# --- 3. merging a.swift into b.swift (screens 04, 05) -------------------------------------
echo "-- 3. Copy to Right, undo, redo, all changes, save"
check "change 2 + Copy to Right: B line 4 = A line 3; undo restores, redo re-applies" \
    unit copyToRightOnChangeTwoUndoesAndRedoes
check "every change copied left to right and saved (unit)" unit applyingEveryChangeLeftToRightMakesBIdenticalToA
check "saved b.swift is byte-identical to a.swift" same_bytes "$OUT/all-right/b.swift" "$TEXT/a.swift"
check "keep both, another choice, reset selection" unit keepBothResetAndAnotherChoice
check "window: merge, undo, redo, save, reset, revert, menu validation" unit windowMergesUndoesSavesAndValidatesMenus
check "editor: TextKit 1 view over the block, one undo step" unit theEditorOpensOverTheBlockAndCommitsAsOneEdit
check "Merge and File menus carry the reference shortcuts" unit mergeMenuHasTheShortcutsOfTheReference
check "offscreen renders before and after Copy to Right" unit rendersMergeStatesOffscreen
check "render: change 2 selected" test -s "$SHOTS/m06-change2-selected.png"
check "render: after Copy to Right" test -s "$SHOTS/m06-after-copy-to-right.png"

# --- 4. UTF-16LE CRLF round trip ------------------------------------------------------------
echo "-- 4. UTF-16LE CRLF edit and save"
check "edited UTF-16LE CRLF file saved (unit)" unit editedLinesKeepUTF16AndCRLFWhenSaved
check "hex compare: saved file == expected bytes" hex_equal "$OUT/utf16-crlf/b.txt" "$OUT/utf16-crlf/expected.txt"
check "saved file keeps the BOM and CRLF" utf16_crlf "$OUT/utf16-crlf/b.txt"

# --- 5. re-diff speed on big_b ---------------------------------------------------------------
echo "-- 5. edit a big_b line: re-diff and repaint"
check "release build: edit + re-diff + repaint <= $(budget 150) ms, aligned" \
    env PRISM_M06_OUT="$OUT" swift test -c release -Xswiftc -enable-testing \
        --filter editingABigFileRediffsAndRepaintsQuickly
check "timing recorded" cat "$OUT/big/timing.txt"

# --- 6. guards against temporary copies ------------------------------------------------------------
echo "-- 6. merging into a \$TMPDIR snapshot"
check "session refuses merges and typing into \$TMPDIR files" unit mergingIntoATemporaryCopyIsRefused
check "window shows the guard and changes nothing" unit windowRefusesMergesIntoTemporaryCopies
check "unreadable encodings are read-only" unit unreadableEncodingsAreReadOnly

# --- 6b. review regressions ---------------------------------------------------------------------
echo "-- 6b. review regressions (folder text tabs, quit, external changes, selection, caret, endings)"
check "review regression tests" unit EditingRegressionTests

# --- 7. GUI (menus through AXPress) ---------------------------------------------------------------
# Never key presses: every action is a menu item pressed through
# Accessibility, and Prism is never brought to the front.
ax_bg() {
    local pid
    pid=$(app_pid) || { echo "ax: Prism is not running" >&2; return 1; }
    local args=(-e 'tell application "System Events"'
                -e "tell (first process whose unix id is $pid)")
    local line
    for line in "$@"; do args+=(-e "$line"); done
    args+=(-e 'end tell' -e 'end tell')
    with_timeout 20 osascript "${args[@]}"
}

menu() {
    ax_bg "click menu item $(_as_string "$2") of menu $(_as_string "$1") of menu bar item $(_as_string "$1") of menu bar 1" \
        >/dev/null
}

perf_count() { cat "$PERF" 2>/dev/null | grep -c "\"event\":\"$1\"" || true; }

# wait_count <event> <n>: waits until the perf log has at least n such events.
wait_count() {
    local deadline=$((SECONDS + 15))
    while (( $(perf_count "$1") < $2 )); do
        (( SECONDS >= deadline )) && { echo "no $2th $1 event"; return 1; }
        sleep 0.2
    done
}

m06_launch() {
    : > "$PERF"
    if app_pid >/dev/null; then echo "an instance of $ACCEPT_APP is already running" >&2; return 1; fi
    open -n -g --env "PRISM_PERF_LOG=$PERF" --env PRISM_TESTING=1 --env PRISM_SHOW_ABOUT=0 \
        "$ACCEPT_APP" --args -prism.text.viewMode blocks "$@" || return 1
    wait_until 15 app_pid || return 1
    # shellcheck disable=SC2034  # read by app_quit and the exit trap (lib.sh)
    ACCEPT_APP_PID=$(app_pid)
    wait_count firstPaint 1
}

line_equals() { [[ "$(sed -n "$2p" "$1")" == "$(sed -n "$4p" "$3")" ]] && echo "$1:$2 == $3:$4"; }

gui_merge() {
    local n=$(( $(perf_count rediff) + 1 ))
    menu Merge "Copy to Right" || return 1
    wait_count rediff "$n"
}

# gui_menu_rediff <menu> <item>: presses the item and waits for the re-diff
# it causes. The Edit menu names the next Undo or Redo only once the last
# one has run, so the following step must not look for it earlier.
gui_menu_rediff() {
    local n=$(( $(perf_count rediff) + 1 ))
    menu "$1" "$2" || return 1
    wait_count rediff "$n"
}

gui_first_merge() {
    menu View "Next Change" && gui_merge
}

# Copies every change to the right. A change that is already copied (the
# one copied before the undo and redo) gives no re-diff, so the count of
# rediff events is not a measure: each press waits briefly for its re-diff,
# and the end state is checked after saving (b.swift == a.swift).
gui_all_right() {
    local n
    for _ in 1 2 3 4 5 6 7 8; do
        menu View "Next Change" || return 1
        n=$(( $(perf_count rediff) + 1 ))
        menu Merge "Copy to Right" || return 1
        wait_until 3 bash -c "(( \$(grep -c '\"event\":\"rediff\"' '$PERF') >= $n ))" || echo "no re-diff (already copied?)"
    done
    grep '"event":"rediff"' "$PERF" | tail -n 1
}

gui_refused() {
    menu View "Next Change" || return 1
    menu Merge "Copy to Right" || return 1
    wait_count editRefused 1 || return 1
    grep '"event":"editRefused"' "$PERF" | tail -n 1
    ax_bg 'click button "OK" of sheet 1 of window 1' >/dev/null || true
}

if gui_available && [[ "${CI:-}" != "true" ]]; then
    echo "-- 7. GUI: menus pressed through Accessibility (PRISM_TESTING=1)"
    check "scripts/bundle.sh succeeds" scripts/bundle.sh
    cp "$TEXT/a.swift" "$TEXT/b.swift" "$WORK/"
    check "launch a.swift b.swift" m06_launch "$WORK/a.swift" "$WORK/b.swift"
    check "View > Next Change, Merge > Copy to Right" gui_first_merge
    check "label stays Change 2 of 8" bash -c "grep '\"event\":\"rediff\"' '$PERF' | tail -n 1 | grep -F '\"label\":\"Change 2 of 8\"'"
    capture after-copy-to-right
    check "Edit > Undo Copy to Right" gui_menu_rediff Edit "Undo Copy to Right"
    check "Edit > Redo Copy to Right" gui_menu_rediff Edit "Redo Copy to Right"
    check "File > Save" menu File "Save"
    sleep 1
    check "saved B line 4 = A line 3" line_equals "$WORK/b.swift" 4 "$WORK/a.swift" 3
    check "every change copied to the right" gui_all_right
    check "File > Save" menu File "Save"
    sleep 1
    check "b.swift is byte-identical to a.swift" same_bytes "$WORK/b.swift" "$WORK/a.swift"
    check "quit" app_quit

    SNAP=$(mktemp -d "${TMPDIR:-/tmp}/prism-m06-snapshot.XXXXXX")
    cp "$TEXT/a.swift" "$TEXT/b.swift" "$SNAP/"
    check "launch a snapshot pair in \$TMPDIR" m06_launch "$SNAP/a.swift" "$SNAP/b.swift"
    check "Copy to Right into the snapshot shows the guard" gui_refused
    capture snapshot-guard
    check "snapshot b.swift unchanged" same_bytes "$SNAP/b.swift" "$TEXT/b.swift"
    check "quit" app_quit
    rm -rf "$SNAP"
else
    echo "-- 7. GUI section skipped (headless): menus, undo, save and the guard are covered by section 3 and 6"
fi

accept_summary
