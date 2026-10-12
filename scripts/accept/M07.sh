#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M7 (three-way merge and git mergetool).
# Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/M07.sh             local run; adds the GUI section when
#                                     Accessibility is granted
#   CI=true scripts/accept/M07.sh     headless: never launches the app
#
# Every git command runs with a temporary HOME and GIT_CONFIG_GLOBAL (and
# no system config), so the user's ~/.gitconfig is never read or written;
# the script checks that it is byte-identical afterwards. prism talks to a
# socket in a temporary folder, and PRISM_APP_PATH points nowhere except in
# the GUI section, which starts build/Prism.app on purpose. Headless, the
# app's part is played by the stub server (PrismIPCStub), which merges the
# files with DiffCore, resolves every conflict with --merge-choice, saves
# the result and reports the merge resolved (or, with none, unresolved).
#
# The GUI section drives build/Prism.app only through AXPress on menu items
# and sheet buttons (scripts/accept/tools/axpress, by PID, never key presses
# and never bringing Prism to the front) with PRISM_TESTING=1, and takes the
# shared GUI lock.
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (the unit
#                               tests this script needs still run)
#   PRISM_ACCEPT_HEADLESS=1     force headless mode locally
#
# Mapping of the MILESTONES.md M7 acceptance bullets to sections below:
#   git mergetool -y -t prism, Choose Left, Cmd-S, Cmd-W: git exit 0,
#     the file has the left line, git status shows it resolved      -> 5 (stub), 6 (window, unit), 8 (GUI)
#   Cmd-W then Don't Resolve: git exit 1, "merge of ... failed",
#     the file stays UU                                             -> 5 (stub), 6 (window, unit), 8 (GUI)
#   corpus tests/corpus/merge/*: auto-resolution == golden          -> 3 (engine, prism merge3) and 6 (window)
#   layout matches screens 21/22/24 structurally                    -> 7 (offscreen renders), 8 (GUI screenshots)
#   prism --merge grammar, help and exit codes; mergetool.prism.*
#     install and byte-for-byte restore                             -> 4
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M07

readonly CORPUS="$ACCEPT_ROOT/Tests/corpus"
readonly OUT="$ACCEPT_DIR/out"
readonly SHOTS="$ACCEPT_DIR/shots"
rm -rf "$OUT" "$SHOTS"
mkdir -p "$OUT" "$SHOTS"

# The user's git config, to prove it is untouched at the end.
REAL_GITCONFIG="$HOME/.gitconfig"
REAL_GITCONFIG_SUM=$( [[ -f "$REAL_GITCONFIG" ]] && shasum -a 256 "$REAL_GITCONFIG" | cut -d' ' -f1 || echo absent)
readonly REAL_GITCONFIG REAL_GITCONFIG_SUM
# SwiftPM keeps its caches under the real home.
readonly REAL_HOME="$HOME"

# A short folder: socket paths are limited to 103 bytes.
SCRATCH="$(mktemp -d /tmp/prism-m07.XXXXXX)"
readonly SCRATCH
mkdir -p "$SCRATCH/home"
: > "$SCRATCH/gitconfig"
export HOME="$SCRATCH/home"
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PRISM_SOCKET_PATH="$SCRATCH/s.sock"
# prism must never start a real app outside the GUI section.
export PRISM_APP_PATH=/nonexistent/Prism.app
STUB_PID=""

GUI_LOCK="${PRISM_GUI_LOCK:-/private/tmp/claude-501/prism-gui.lock}"
GUI_LOCKED=0

m07_cleanup() {
    stub_stop
    accept_cleanup
    gui_unlock
    rm -rf "$SCRATCH"
}
trap m07_cleanup EXIT
trap 'm07_cleanup; exit 130' INT TERM

# unit <filter>: runs the unit tests matching the filter, leaving saved
# files in $OUT and offscreen renders in $SHOTS.
unit() {
    HOME="$REAL_HOME" PRISM_M07_OUT="$OUT" PRISM_M07_SHOTS="$SHOTS" swift test --filter "$1" 2>&1 \
        | grep -v "search path" | tee -a "$ACCEPT_DIR/unit.log" | grep -E "✔|✘|passed|failed|error" | tail -n 40
    return "${PIPESTATUS[0]}"
}

bin_dir() { HOME="$REAL_HOME" swift build --show-bin-path 2>/dev/null; }

# --- 1. guards ---------------------------------------------------------------------
echo "-- 1. guards"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
if git rev-parse -q --verify 'master^{commit}' >/dev/null; then
    check "DCO sign-off (check-dco.sh master..HEAD)" scripts/ci/check-dco.sh master..HEAD
fi

# --- 2. build ------------------------------------------------------------------------
echo "-- 2. build"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
else
    check "release build zero warnings + swift test (build-strict.sh)" env HOME="$REAL_HOME" scripts/ci/build-strict.sh
fi
check "debug build of prism and the stub server" env HOME="$REAL_HOME" swift build
BIN="$(bin_dir)"
readonly CLI="$BIN/prism" PRISM="$BIN/prism" STUB="$BIN/PrismIPCStub"

# --- 3. merge engine and corpus goldens -------------------------------------------------
echo "-- 3. three-way merge engine: corpus goldens"
check "merge corpus manifest (merge.sha256)" bash -c "cd '$CORPUS' && shasum -a 256 -c merge.sha256 --quiet"
check "DiffCore merge tests (goldens, per-pair split, A's lines kept while unresolved)" unit Merge3Tests

merge_case() {
    local dir="$1" args=() want=0
    [[ -f "$dir/args.txt" ]] && read -r -a args < "$dir/args.txt"
    grep -q '"unresolved": 0,' "$dir/expected.json" || want=1
    local got=0
    "$PRISM" merge3 ${args[@]+"${args[@]}"} "$dir/base.txt" "$dir/a.txt" "$dir/b.txt" --json \
        > "$OUT/merge3-$(basename "$dir").json" || got=$?
    [[ "$got" == "$want" ]] || { echo "exit $got, expected $want"; return 1; }
    cmp "$OUT/merge3-$(basename "$dir").json" "$dir/expected.json" && echo "$(basename "$dir"): identical to expected.json"
}
for dir in "$CORPUS"/merge/*/; do
    check "prism merge3 $(basename "$dir") == expected.json" merge_case "${dir%/}"
done
check "split-by-agreement: overlapping edits that agree give no conflict" \
    grep -q '"conflicts": 0,' "$CORPUS/merge/split-by-agreement/expected.json"

# --- 4. prism --merge and the git configuration ---------------------------------------
echo "-- 4. prism --merge, exit codes, mergetool.prism.* install"
check "prism --merge grammar" unit ClientArgumentsTests
check "prism --merge in process: document, exit 0 resolved, 1 otherwise" unit ClientMergeTests
check "prism --supports-capability merges-v1 says YES" bash -c "[[ \$('$CLI' --supports-capability merges-v1) == YES ]]"
check "prism --help documents --merge and git mergetool" \
    bash -c "'$CLI' --help | grep -q -- '--merge --output OUT \\[--base BASE\\]' && '$CLI' --help | grep -q 'git mergetool'"
check "prism --merge without --output is a usage error (exit 1)" \
    bash -c "'$CLI' --merge a b; [[ \$? == 1 ]]"
check "prism --merge --no-wait is a usage error (exit 1)" \
    bash -c "'$CLI' --merge --no-wait --output o a b; [[ \$? == 1 ]]"
check "git config: mergetool.prism.* written and restored byte for byte" unit GitConfigInstallerTests

# --- 5. git mergetool through prism and the stub server -----------------------------------
echo "-- 5. git mergetool -y -t prism (stub server stands in for the app)"

stub_start() {
    stub_stop
    rm -f "$PRISM_SOCKET_PATH"
    "$STUB" serve --socket "$PRISM_SOCKET_PATH" "$@" 2>>"$SCRATCH/stub.log" &
    STUB_PID=$!
    wait_until 10 "$STUB" status --socket "$PRISM_SOCKET_PATH" || { echo "stub did not start"; return 1; }
    echo "stub pid $STUB_PID $*"
}

stub_stop() {
    if [[ -n "$STUB_PID" ]]; then
        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
        STUB_PID=""
    fi
}

# conflict_repo <dir>: master and feature both change line 2 of notes.txt;
# merging feature into master leaves it conflicted.
conflict_repo() {
    local repo="$1"
    rm -rf "$repo"
    mkdir -p "$repo" && cd "$repo" || return 1
    git init --quiet --initial-branch=master --template= &&
        printf 'line1\nline2\nline3\n' > notes.txt && git add notes.txt && git commit --quiet -m init &&
        git checkout --quiet -b feature &&
        printf 'line1\nline2 feature\nline3\n' > notes.txt && git commit --quiet -am feature &&
        git checkout --quiet master &&
        printf 'line1\nline2 main\nline3\n' > notes.txt && git commit --quiet -am main
    git merge --quiet feature >/dev/null 2>&1
    local status=$?
    cd "$ACCEPT_ROOT" || return 1
    (( status != 0 )) || { echo "no conflict"; return 1; }
    echo "conflicted repository at $repo"
}

# configure_mergetool <prism>: the keys Prism's git integration writes.
configure_mergetool() {
    git config --global mergetool.prism.cmd \
        "'$1' --merge --output \"\$MERGED\" --base \"\$BASE\" -- \"\$LOCAL\" --snapshot \"\$REMOTE\" --snapshot" &&
        git config --global mergetool.prism.trustExitCode true &&
        git config --global --get mergetool.prism.cmd
}

# mergetool <repo> <log>: runs git mergetool -y -t prism; prints git's exit.
mergetool() {
    local status=0
    (cd "$1" && with_timeout 120 git mergetool -y -t prism) > "$2" 2>&1 || status=$?
    echo "$status"
}

expect_resolved() {   # expect_resolved <repo> <git exit>
    [[ "$2" == 0 ]] || { echo "git mergetool exited $2"; cat "$OUT/mergetool-resolved.log"; return 1; }
    [[ "$(sed -n 2p "$1/notes.txt")" == "line2 main" ]] || { echo "line 2: $(sed -n 2p "$1/notes.txt")"; return 1; }
    local status
    status=$(cd "$1" && git status --porcelain)
    echo "git status: ${status:-clean}"
    ! grep -q '^UU' <<<"$status" && [[ -z "$(cd "$1" && git diff --name-only --diff-filter=U)" ]]
}

expect_unresolved() { # expect_unresolved <repo> <git exit> <log>
    [[ "$2" != 0 ]] || { echo "git mergetool exited 0"; return 1; }
    grep -F "merge of notes.txt failed" "$3" || return 1
    (cd "$1" && git status --porcelain) | grep '^UU notes.txt'
}

check "mergetool.prism.cmd and trustExitCode set (temporary GIT_CONFIG_GLOBAL)" configure_mergetool "$CLI"
check "conflicted repository" conflict_repo "$SCRATCH/resolved"
check "stub server: merges closed after 300 ms with Choose Left" stub_start --close-after-ms 300 --merge-choice a
RESOLVED_EXIT=$(mergetool "$SCRATCH/resolved" "$OUT/mergetool-resolved.log")
check "Choose Left + save + close: git exit 0, left line, resolved" expect_resolved "$SCRATCH/resolved" "$RESOLVED_EXIT"
check "conflicted repository" conflict_repo "$SCRATCH/unresolved"
check "stub server: merges closed after 300 ms without resolving" stub_start --close-after-ms 300 --merge-choice none
UNRESOLVED_EXIT=$(mergetool "$SCRATCH/unresolved" "$OUT/mergetool-unresolved.log")
check "close without resolving: git exit 1, 'merge of notes.txt failed', file stays UU" \
    expect_unresolved "$SCRATCH/unresolved" "$UNRESOLVED_EXIT" "$OUT/mergetool-unresolved.log"
stub_stop
check "git mergetool end to end (unit, GitSandbox)" unit GitMergetoolTests

# --- 6. the merge window, headless ------------------------------------------------------------
echo "-- 6. merge window (controller and session, no window shown)"
check "Choose Left, save, close: reported resolved, output has the left line" unit windowChooseLeftSaveAndCloseReportsResolved
check "saved output == left version" bash -c "[[ \"\$(cat '$OUT/window-left/merged.txt')\" == \$'line1\\nline2 main\\nline3' ]]"
check "Review Conflicts keeps the window; Don't Resolve reports unresolved" unit windowClosedWithoutResolvingReportsUnresolved
check "saved then changed again is not resolved" unit savedButChangedAgainIsNotResolved
check "conflict navigation and menu validation" unit conflictNavigationAndMenuValidation
check "typing in the result column resolves" unit typingInTheResultColumnResolves
check "session: choices, undo, edits, no base" unit "chooseLeftThenSaveResolvesTheMerge|everyChoiceAndResetGivesItsText|choicesUndoAndRedo|typingOverAConflictResolvesIt|withoutABaseEveryDifferenceIsAConflict"
check "window's automatic resolution == corpus goldens" unit automaticResolutionMatchesTheGolden
check "Merge menu renamed (Choose Left/Right/Both), Previous/Next Conflict" unit mergeMenuIsRenamedForThreeWayMerges
check "review fixes: untouched editor, documents refused, resolved at quit, exact whitespace, lossy save, no base" \
    unit MergeFixTests

# --- 7. layouts (offscreen renders for comparison with screens 21, 22, 24) ----------------------
echo "-- 7. layouts"
check "rows of Blocks, Fluid and Unified" unit layoutsPlaceTheConflictAndItsPlaceholder
check "offscreen renders" unit rendersMergeLayoutsOffscreen
for name in m07-unified m07-blocks m07-fluid m07-fluid-resolved-left m07-mixed-fluid; do
    check "render: $name.png" test -s "$SHOTS/$name.png"
done

# --- 8. GUI (AXPress through accessibility) ----------------------------------------------------
gui_lock() {
    until mkdir "$GUI_LOCK" 2>/dev/null; do
        if ! grep -q '^OWNER-HOLD' "$GUI_LOCK/owner" 2>/dev/null \
            && [[ -n "$(find "$GUI_LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]]; then
            rm -rf "$GUI_LOCK"
            continue
        fi
        sleep 5
    done
    echo "m07-merge3 $$" > "$GUI_LOCK/owner"
    GUI_LOCKED=1
}

gui_unlock() {
    (( GUI_LOCKED )) && rm -rf "$GUI_LOCK"
    GUI_LOCKED=0
}

ax() { accept_tool axpress "$(app_pid)" "$@"; }

PERF="$ACCEPT_DIR/perf.log"
perf_has() { grep -q "\"event\":\"$1\"" "$PERF" 2>/dev/null && grep "\"event\":\"$1\"" "$PERF" | tail -n 1; }

# gui_mergetool <repo> <log>: starts git mergetool in the background; prism
# launches build/Prism.app (PRISM_TESTING=1) and waits for the merge window.
gui_mergetool() {
    (cd "$1" && PRISM_APP_PATH="$ACCEPT_APP" PRISM_PERF_LOG="$PERF" with_timeout 120 git mergetool -y -t prism \
        > "$2" 2>&1; echo $? > "$2.status") &
    wait_until 30 perf_has mergeLoaded || { echo "no merge window"; return 1; }
    ACCEPT_APP_PID=$(app_pid)
    perf_has mergeLoaded
}

git_exit() { wait_until 30 test -s "$1.status" && cat "$1.status"; }

gui_resolve() {
    ax menu Merge "Choose Left" && wait_until 10 perf_has mergeChoice &&
        ax menu File "Save" && wait_until 10 perf_has mergeSaved &&
        ax menu File "Close" && [[ "$(git_exit "$OUT/gui-resolved.log")" == 0 ]]
}

gui_dont_resolve() {
    ax menu File "Close" && wait_until 10 perf_has mergeCloseQuestion &&
        ax button "Don’t Resolve"
    [[ "$(git_exit "$OUT/gui-unresolved.log")" != 0 ]]
}

if gui_available && [[ "${CI:-}" != "true" ]]; then
    echo "-- 8. GUI: git mergetool with build/Prism.app, menus pressed through Accessibility (PRISM_TESTING=1)"
    check "scripts/bundle.sh succeeds" env HOME="$REAL_HOME" scripts/bundle.sh
    gui_lock
    : > "$PERF"
    configure_mergetool "$ACCEPT_APP/Contents/Helpers/prism" >/dev/null
    check "conflicted repository" conflict_repo "$SCRATCH/gui-resolved"
    check "git mergetool opens the merge window (Unified first)" gui_mergetool "$SCRATCH/gui-resolved" "$OUT/gui-resolved.log"
    capture merge-unified
    check "View > Blocks" ax menu View "Blocks"
    capture merge-blocks
    check "View > Fluid" ax menu View "Fluid"
    check "Choose Left, File > Save, File > Close: git exit 0" gui_resolve
    check "file has the left line and is resolved" expect_resolved "$SCRATCH/gui-resolved" 0
    : > "$PERF"
    check "conflicted repository" conflict_repo "$SCRATCH/gui-unresolved"
    check "git mergetool opens the merge window" gui_mergetool "$SCRATCH/gui-unresolved" "$OUT/gui-unresolved.log"
    check "File > Close, Don't Resolve: git exit 1" gui_dont_resolve
    check "'merge of notes.txt failed', file stays UU" \
        expect_unresolved "$SCRATCH/gui-unresolved" 1 "$OUT/gui-unresolved.log"
    check "quit" app_quit
    gui_unlock
else
    echo "-- 8. GUI section skipped (headless): sections 5 and 6 cover the mergetool flows"
fi

# --- 9. the user's git configuration ------------------------------------------------------------
echo "-- 9. safety"
real_config_untouched() {
    local now
    now=$( [[ -f "$REAL_GITCONFIG" ]] && shasum -a 256 "$REAL_GITCONFIG" | cut -d' ' -f1 || echo absent)
    echo "~/.gitconfig: $now"
    [[ "$now" == "$REAL_GITCONFIG_SUM" ]]
}
check "the real ~/.gitconfig is byte-identical" real_config_untouched

accept_summary
