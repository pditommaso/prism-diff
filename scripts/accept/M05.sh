#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M5 (prism <-> app IPC, git difftool
# changesets, Integration window). Exit status: 0 when every check passes,
# 1 otherwise.
#
#   scripts/accept/M05.sh             local run
#   CI=true scripts/accept/M05.sh     headless run
#
# Safety: every git command runs with a temporary HOME and GIT_CONFIG_GLOBAL
# (and no system config); the socket lives in a temporary folder
# (PRISM_SOCKET_PATH); installs go to a temporary prefix. Nothing touches
# ~/.gitconfig, /usr/local/bin or ~/bin.
#
# Sections 2-6 run the git difftool scenarios against PrismIPCStub, the
# headless stand-in for the app's socket server (same protocol, same
# router), so they also run on CI. Section 9 runs them again against our
# build/Prism.app (cold start, changeset windows, --wait with Cmd-W, killing
# the app, the Integration window), holding the shared GUI lock
# (/private/tmp/claude-501/prism-gui.lock) for that section only. The
# `status` command of PrismIPCStub lists the documents either server holds;
# the app also reports windows in its perf log (PRISM_PERF_LOG).
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (debug
#                               products are still built)
#   PRISM_ACCEPT_QUICK=1        100 files instead of 500, 60 + 40 instead of
#                               300 + 200 (for iteration; not acceptance)
#   PRISM_ACCEPT_NO_APP=1       skip section 9 (implied by CI=true)
#   PRISM_ACCEPT_HEADLESS=1     section 9 without UI scripting (no Cmd-W,
#                               Shift-Cmd-Down or Integration clicks)
#
# Mapping of the MILESTONES.md M5 acceptance bullets to sections below:
#   git difftool, 3 files -> one window, 3 rows, CLI exits 0     -> 2, 9
#   500-file difftool: one changeset, 500 rows, no prism left   -> 3, 9
#   two concurrent runs (300 + 200) -> two changesets            -> 4, 9
#   prism --wait blocks until close; app killed -> exit 1 <100ms-> 5, 9
#   cold start to document visible <= 1 s                        -> 9
#   warm round trip median <= 1 ms                               -> 6, 9
#   connection from another UID refused                          -> 7
#   foreign prism: offer prism-diff, never overwrite; else silent -> 8, 9
#   git config install writes difftool.prism.cmd, remove
#   restores byte-identically                                    -> 8, 9
#   changeset window structure (screen 20), Integration window
#   (screen 36): screenshots in build/accept/M05/ for review     -> 9
#   global definition of done                                    -> 1
#
# Output of every check: build/accept/M05/checks.log.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M05

if [[ "${PRISM_ACCEPT_QUICK:-}" == 1 ]]; then
    BIG=100; RUN1=60; RUN2=40
else
    BIG=500; RUN1=300; RUN2=200
fi
readonly BIG RUN1 RUN2

# A short folder: socket paths are limited to 103 bytes.
SCRATCH="$(mktemp -d /tmp/prism-m05.XXXXXX)"
readonly SCRATCH
mkdir -p "$SCRATCH/home"
: > "$SCRATCH/gitconfig"
export HOME="$SCRATCH/home"
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PRISM_SOCKET_PATH="$SCRATCH/s.sock"
# prism must never start a real app from here.
export PRISM_APP_PATH="$SCRATCH/no-such/Prism.app"
STUB_PID=""

GUI_LOCK=/private/tmp/claude-501/prism-gui.lock
GUI_LOCK_HELD=""

m05_cleanup() {
    stub_stop
    # Whatever happened, no dialog is left up and our app is quit.
    if [[ -z "${ACCEPT_APP_PID:-}" ]]; then ACCEPT_APP_PID=$(app_pid 2>/dev/null || true); fi
    if [[ -n "${ACCEPT_APP_PID:-}" ]]; then dismiss_sheets >/dev/null 2>&1 || true; fi
    accept_cleanup
    gui_unlock
    rm -rf "$SCRATCH"
}

# gui_lock: takes the lock shared by the builders that drive Prism.app
# (stale after 20 minutes, unless its owner file starts with OWNER-HOLD).
# Gives up after PRISM_GUI_LOCK_TIMEOUT seconds (default 600), naming the
# holder; the caller then skips the app section.
gui_lock() {
    local timeout="${PRISM_GUI_LOCK_TIMEOUT:-600}"
    local deadline=$((SECONDS + timeout))
    mkdir -p "$(dirname "$GUI_LOCK")"
    until mkdir "$GUI_LOCK" 2>/dev/null; do
        # A hold placed by the owner is never treated as stale.
        if ! grep -q '^OWNER-HOLD' "$GUI_LOCK/owner" 2>/dev/null \
            && [[ -n "$(find "$GUI_LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]]; then
            rm -rf "$GUI_LOCK"
            continue
        fi
        if (( SECONDS >= deadline )); then
            echo "gave up after ${timeout} s waiting for the GUI lock $GUI_LOCK, held by: $(cat "$GUI_LOCK/owner" 2>/dev/null || echo unknown)"
            return 1
        fi
        sleep 5
    done
    echo "m05-prism-ipc $$" > "$GUI_LOCK/owner"
    GUI_LOCK_HELD=1
}

# wait_for_other_prisms: other builders' Prism.app instances share our
# bundle identifier, so automation aimed at "Prism" may reach ours; wait
# (up to 15 minutes) until none runs, as the builder brief asks.
wait_for_other_prisms() {
    local deadline=$((SECONDS + 900)) others
    while true; do
        others=$(pgrep -x Prism 2>/dev/null | while read -r pid; do
            [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$ACCEPT_EXEC" ]] || echo "$pid"
        done)
        [[ -z "$others" ]] && return 0
        (( SECONDS >= deadline )) && { echo "other Prism instances still running: $others"; return 1; }
        sleep 10
    done
}

gui_unlock() {
    if [[ -n "$GUI_LOCK_HELD" ]]; then
        rm -rf "$GUI_LOCK"
        GUI_LOCK_HELD=""
    fi
}
trap m05_cleanup EXIT
trap 'm05_cleanup; exit 130' INT TERM

BIN="$ACCEPT_ROOT/.build/debug"
prism_bin="$BIN/prism"
STUB="$BIN/PrismIPCStub"

# --- helpers -------------------------------------------------------------------

# kill_tree <pid>: SIGKILL to a process and all its descendants.
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
    kill -KILL "$1" 2>/dev/null || true
}

# timed <seconds> <command...>: runs the command (a function or a program)
# in a subshell and kills it, with everything it started, when it takes
# longer: a hang becomes a failure (status 124), never a blocked run. Runs
# after a timeout hook (timeout_hook) to clean up, e.g. dismiss dialogs.
# Variables set by the command do not survive: app_check re-reads the app
# PID afterwards.
timed() {
    local seconds="$1"; shift
    ( "$@" ) &
    local child=$! deadline=$((SECONDS + seconds))
    while kill -0 "$child" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            kill_tree "$child"
            wait "$child" 2>/dev/null
            echo "TIMEOUT: gave up after ${seconds} s"
            timeout_hook
            return 124
        fi
        sleep 0.2
    done
    wait "$child"
}

timeout_hook() {
    dismiss_sheets >/dev/null 2>&1 || true
}

# dismiss_sheets: presses the last button (Cancel, Leave It, ...) of any
# sheet left on our app's windows, and any modal alert window.
dismiss_sheets() {
    app_pid >/dev/null || return 0
    ax_bg 'repeat with w in windows' \
        '  repeat while (count of sheets of w) > 0' \
        '    set s to sheet 1 of w' \
        '    click (last button of s)' \
        '    delay 0.3' \
        '  end repeat' \
        'end repeat'
}

# app_check <seconds> <description> <command...>: a check for the app
# section, bounded by <seconds>; afterwards ACCEPT_APP_PID is re-read so
# that the exit trap always quits the instance that is running.
app_check() {
    local seconds="$1" description="$2"; shift 2
    check "$description" timed "$seconds" "$@"
    ACCEPT_APP_PID=$(app_pid 2>/dev/null || true)
}

now_ms() {
    /usr/bin/python3 -I -c 'import time; print(int(time.time() * 1000))'
}

stub_start() {
    stub_stop
    rm -f "$PRISM_SOCKET_PATH"
    "$STUB" serve --socket "$PRISM_SOCKET_PATH" "$@" 2>>"$SCRATCH/stub.log" &
    STUB_PID=$!
    wait_until 10 "$STUB" status --socket "$PRISM_SOCKET_PATH" || { echo "stub did not start"; return 1; }
    echo "stub pid $STUB_PID"
}

stub_stop() {
    if [[ -n "$STUB_PID" ]]; then
        kill -TERM "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
        STUB_PID=""
    fi
}

# status_json: the server's document list.
status_json() {
    "$STUB" status --socket "$PRISM_SOCKET_PATH"
}

# changesets <expected row counts...>: the server holds exactly that many
# partial changesets with those row counts (any order), all complete. With
# CS_TITLES="title|title", only changesets with those titles count.
changesets() {
    local json
    json=$(status_json) || return 1
    CS_TITLES="${CS_TITLES:-}" /usr/bin/python3 -I -c '
import json, os, sys
titles = [t for t in os.environ["CS_TITLES"].split("|") if t]
docs = [d for d in json.loads(sys.argv[1]) if d["kind"] == "partialChangeset"
        and (not titles or d["title"] in titles)]
want = sorted(int(n) for n in sys.argv[2:])
got = sorted(len(d["relativePaths"]) for d in docs)
print("changesets:", [(d["title"], len(d["relativePaths"]), d["isComplete"]) for d in docs])
ok = got == want and all(d["isComplete"] for d in docs)
for d in docs:
    if len(set(d["relativePaths"])) != len(d["relativePaths"]):
        print("duplicate rows in", d["title"]); ok = False
sys.exit(0 if ok else 1)
' "$json" "$@"
}

# titled <titles> <command...>: runs the command with CS_TITLES set.
titled() {
    local CS_TITLES="$1"; shift
    "$@"
}

# make_repo <dir> <n>: a repository with n committed, then modified files.
make_repo() {
    local dir="$1" n="$2" i
    mkdir -p "$dir"
    git -C "$dir" init --quiet --initial-branch=master --template=
    for ((i = 0; i < n; i++)); do printf 'line 1\nline 2\n' > "$dir/$(printf 'file%03d.txt' "$i")"; done
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgSign=false commit --quiet --no-verify -m init
    for ((i = 0; i < n; i++)); do printf 'line 1\nline 2 changed\n' > "$dir/$(printf 'file%03d.txt' "$i")"; done
}

configure_difftool() {
    # The command Prism's git integration installs, with the built prism,
    # wrapped to log each call's exit status and duration.
    cat > "$SCRATCH/prism-logged" <<EOF
#!/bin/sh
start=\$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
"$prism_bin" "\$@"
rc=\$?
end=\$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
echo "\$rc \$((end - start))" >> "$SCRATCH/calls.log"
exit \$rc
EOF
    chmod +x "$SCRATCH/prism-logged"
    git config --global difftool.prism.cmd \
        "'$SCRATCH/prism-logged' --partial-changeset --relative-path \"\$MERGED\" -- \"\$LOCAL\" \"\$REMOTE\""
}

# calls_ok <count>: the log has <count> calls, all exit 0, each under 2 s.
calls_ok() {
    local want="$1" n bad slow
    n=$(wc -l < "$SCRATCH/calls.log" | tr -d ' ')
    bad=$(awk '$1 != 0' "$SCRATCH/calls.log" | wc -l | tr -d ' ')
    slow=$(awk '$2 > 2000' "$SCRATCH/calls.log" | wc -l | tr -d ' ')
    echo "calls=$n nonzero=$bad slow=$slow max_ms=$(awk 'm < $2 { m = $2 } END { print m + 0 }' "$SCRATCH/calls.log")"
    [[ "$n" == "$want" && "$bad" == 0 && "$slow" == 0 ]]
}

no_client_left() {
    if pgrep -f "$prism_bin" >/dev/null; then
        pgrep -fl "$prism_bin"
        return 1
    fi
}

difftool_three() {
    local repo="$SCRATCH/three/repo"
    rm -rf "$SCRATCH/three"
    mkdir -p "$SCRATCH/three"
    Tests/corpus/scripts/make-repo.sh "$repo" >/dev/null || return 1
    echo "edited" > "$repo/notes.txt"
    : > "$SCRATCH/calls.log"
    (cd "$repo" && git difftool -y -t prism --trust-exit-code) || return 1
    calls_ok 3
}

three_rows_one_changeset() {
    CS_TITLES="Changes in repo" changesets 3 || return 1
    local paths
    paths=$(status_json | /usr/bin/python3 -I -c '
import json, sys
print(",".join(next(d for d in json.load(sys.stdin) if d["title"] == "Changes in repo")["relativePaths"]))')
    echo "rows: $paths"
    [[ "$paths" == "conf.ini,main.swift,notes.txt" ]]
}

difftool_big() {
    rm -rf "$SCRATCH/big"
    make_repo "$SCRATCH/big" "$BIG" || return 1
    : > "$SCRATCH/calls.log"
    (cd "$SCRATCH/big" && git difftool -y -t prism --trust-exit-code) || return 1
    calls_ok "$BIG"
}

difftool_concurrent() {
    rm -rf "$SCRATCH/c1" "$SCRATCH/c2"
    make_repo "$SCRATCH/c1" "$RUN1" || return 1
    make_repo "$SCRATCH/c2" "$RUN2" || return 1
    : > "$SCRATCH/calls.log"
    local p1 p2 s1=0 s2=0
    (cd "$SCRATCH/c1" && git difftool -y -t prism --trust-exit-code) & p1=$!
    (cd "$SCRATCH/c2" && git difftool -y -t prism --trust-exit-code) & p2=$!
    wait "$p1" || s1=$?
    wait "$p2" || s2=$?
    echo "runs exited $s1 $s2"
    (( s1 == 0 && s2 == 0 )) && calls_ok $((RUN1 + RUN2))
}

# wait_until_closed: prism --wait stays blocked until the document is
# closed (SIGUSR1 makes the stub close every document), then exits 0.
wait_until_closed() {
    local pid status=0
    "$prism_bin" --wait Tests/corpus/fixtures/text/a.swift Tests/corpus/fixtures/text/b.swift &
    pid=$!
    sleep 1
    kill -0 "$pid" 2>/dev/null || { echo "prism --wait returned before the close"; return 1; }
    kill -USR1 "$STUB_PID"
    wait "$pid" || status=$?
    echo "prism --wait exited $status after the close"
    (( status == 0 ))
}

# killed_app_exits_one: SIGKILL the server while prism waits: prism exits
# 1 within 100 ms.
killed_app_exits_one() {
    local pid status=0
    "$prism_bin" -w Tests/corpus/fixtures/text/a.swift Tests/corpus/fixtures/text/b.swift 2>/dev/null &
    pid=$!
    sleep 1
    kill -0 "$pid" 2>/dev/null || { echo "prism -w returned early"; return 1; }
    # Poll in perl at 1 ms resolution, from the kill to prism's exit.
    /usr/bin/perl -MTime::HiRes=time,usleep -e '
        my ($server, $client) = @ARGV;
        my $t0 = time; kill "KILL", $server;
        while (kill 0, $client) { usleep 500; last if time - $t0 > 2; }
        printf "latency_ms=%.1f\n", (time - $t0) * 1000;
        exit((time - $t0) < 0.1 ? 0 : 1);' "$STUB_PID" "$pid" || status=$?
    wait "$pid"
    local rc=$?
    STUB_PID=""
    echo "prism exit status $rc"
    (( status == 0 && rc == 1 ))
}

warm_round_trip() {
    local json median
    json=$("$STUB" bench --socket "$PRISM_SOCKET_PATH" --count 500) || return 1
    echo "$json"
    median=$(/usr/bin/python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["median_ms"])' "$json")
    /usr/bin/python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 1.0 else 1)' "$median"
}

socket_is_private() {
    local mode
    mode=$(stat -f '%Lp' "$PRISM_SOCKET_PATH") || return 1
    echo "socket mode $mode"
    [[ "$mode" == 600 ]]
}

swift_test() {     # swift_test <filter>
    swift test --skip-build --filter "$1" 2>&1 | tail -n 3
    return "${PIPESTATUS[0]}"
}

# --- 1. build and guards -------------------------------------------------------
echo "-- 1. build and guards"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
else
    check "release build zero warnings + swift test (build-strict.sh)" scripts/ci/build-strict.sh
fi
check "debug products build (prism, PrismIPCStub, tests)" swift build --build-tests
check "SPDX headers" scripts/ci/check-spdx.sh
check "clean-room rules" scripts/ci/check-cleanroom.sh

# --- 2. git difftool, three files ----------------------------------------------
echo "-- 2. git difftool: three modified files"
check "stub server starts on a 0600 socket" stub_start
check "socket mode is 0600" socket_is_private
configure_difftool
check "git difftool -y -t prism: 3 calls, each exits 0 at once" difftool_three
check "one changeset 'Changes in repo' with 3 rows, complete" three_rows_one_changeset
check "no prism process left" no_client_left

# --- 3. 500 files ---------------------------------------------------------------
echo "-- 3. git difftool: $BIG files"
check "stub server restarts" stub_start
check "git difftool over $BIG files: every call exits 0 at once" difftool_big
check "one changeset with $BIG rows" titled "Changes in big" changesets "$BIG"
check "no prism process left" no_client_left

# --- 4. concurrent runs ----------------------------------------------------------
echo "-- 4. two concurrent git difftool runs ($RUN1 + $RUN2)"
check "stub server restarts" stub_start
check "both runs succeed" difftool_concurrent
check "two separate changesets of $RUN1 and $RUN2 rows" titled "Changes in c1|Changes in c2" changesets "$RUN1" "$RUN2"
check "no prism process left" no_client_left

# --- 5. --wait -------------------------------------------------------------------
echo "-- 5. prism --wait"
check "stub server restarts" stub_start
check "prism --wait blocks until the document closes, then exits 0" timed 60 wait_until_closed
check "server killed during --wait: prism exits 1 within 100 ms" timed 60 killed_app_exits_one

# --- 6. latency --------------------------------------------------------------------
echo "-- 6. latency"
check "stub server restarts" stub_start
check "warm round trip median <= 1 ms (500 requests)" warm_round_trip
stub_stop

# --- 7. security -------------------------------------------------------------------
echo "-- 7. security"
check "peer from another UID is refused (simulated peer-UID check)" swift_test "refusesAnotherUser|peerUIDCheckSeesTheRealUser"

# --- 8. integration ------------------------------------------------------------------
echo "-- 8. integration (temporary prefix and gitconfig only)"
check "foreign prism: conflict, prism-diff instead, none: silent install" \
    swift_test "CommandLineToolInstallerTests"
check "git config: install writes difftool.prism.cmd, remove restores byte for byte" \
    swift_test "GitConfigInstallerTests"

# --- 9. the app -----------------------------------------------------------------------

APP_PERF="$ACCEPT_DIR/perf.log"
APP_SOCKET="$SCRATCH/app.sock"
FIX_A="$ACCEPT_ROOT/Tests/corpus/fixtures/text/a.swift"
FIX_B="$ACCEPT_ROOT/Tests/corpus/fixtures/text/b.swift"

# use_app: point prism and the status queries at our app.
use_app() {
    export PRISM_SOCKET_PATH="$APP_SOCKET"
    export PRISM_APP_PATH="$ACCEPT_APP"
    export PRISM_PERF_LOG="$APP_PERF"
}

no_app_running() {
    if app_pid >/dev/null; then
        echo "an instance of $ACCEPT_APP is already running"
        return 1
    fi
}

# perf_last <event> <python expression over d>: value for the last event.
perf_last() {
    [[ -f "$APP_PERF" ]] || return 1
    /usr/bin/python3 -I -c '
import json, sys
value = None
for line in open(sys.argv[1]):
    d = json.loads(line)
    if d.get("event") == sys.argv[2]:
        value = eval(sys.argv[3], {"d": d})
if value is None:
    sys.exit(1)
print(value)' "$APP_PERF" "$1" "$2"
}

# perf_has <event> <python condition over d>: some event satisfies it.
perf_has() {
    [[ -f "$APP_PERF" ]] || return 1
    /usr/bin/python3 -I -c '
import json, sys
for line in open(sys.argv[1]):
    d = json.loads(line)
    if d.get("event") == sys.argv[2] and eval(sys.argv[3], {"d": d}):
        sys.exit(0)
sys.exit(1)' "$APP_PERF" "$1" "$2"
}

# cold_start: with no Prism running, `prism a b` starts the app, which
# draws the comparison within 1 s of prism starting.
cold_start() {
    rm -f "$APP_PERF" "$APP_SOCKET"
    local t0 status=0 painted elapsed
    t0=$(now_ms)
    "$prism_bin" "$FIX_A" "$FIX_B" || status=$?
    echo "prism exited $status"
    (( status == 0 )) || return 1
    wait_until 10 perf_last firstPaint 'd["wallMs"]' || { echo "no firstPaint"; return 1; }
    ACCEPT_APP_PID=$(app_pid) || { echo "app not running"; return 1; }
    painted=$(perf_last firstPaint 'int(d["wallMs"])')
    elapsed=$((painted - t0))
    echo "cold start: prism start -> first paint ${elapsed} ms (app pid $ACCEPT_APP_PID)"
    (( elapsed <= 1000 ))
}

# only_window: our app shows exactly one normal window, the comparison
# window (over 600 points wide; About is 360), so no About or launch
# window came up.
only_window() {
    local lines n
    lines=$(_app_windows | awk -F'\t' '$2 == 0')
    echo "${lines:-<no windows>}"
    n=$(grep -c . <<<"$lines")
    local width
    width=$(cut -f3 <<<"$lines" | cut -d, -f3)
    (( n == 1 && width > 600 )) && [[ "$(cut -f5 <<<"$lines")" != "About Prism" ]]
}

# window_count <title> <n>: our app shows n normal windows with that title.
window_count() {
    local n
    n=$(_app_windows | awk -F'\t' -v t="$1" '$2 == 0 && $5 == t' | grep -c .)
    echo "windows titled '$1': $n"
    (( n == $2 ))
}

# changeset_window <title> <rows>: the app reported a complete changeset
# window with that title whose sidebar lists <rows> files, and shows
# exactly one window with that title.
changeset_window() {
    wait_until 10 perf_has changesetCompleted "d['title'] == '$1' and d['rows'] == $2 and d['sidebarRows'] == $2" \
        || { echo "no complete changeset '$1' with $2 sidebar rows"; grep changeset "$APP_PERF" | tail -n 3; return 1; }
    window_count "$1" 1
}

# ax_bg <applescript lines...>: like lib.sh's _ax, but never brings Prism to
# the front: menu items and buttons are pressed through Accessibility
# (AXPress), which works on a background app.
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

# ax_menu <menu> <item>: presses a menu bar item without activating Prism.
ax_menu() {
    ax_bg "click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null
}

# ax_menu_enabled <menu> <item>: the menu item is enabled. Commands sent
# down the responder chain (Next File, Close) are disabled while Prism is
# not the active app, since it then has no key or main window.
ax_menu_enabled() {
    [[ "$(ax_bg "get enabled of menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1")" == true ]]
}

# ax_window_named <title>: Prism has a window with that title (AX).
ax_window_named() {
    ax_bg 'set AppleScript'"'"'s text item delimiters to linefeed' 'return (name of every window) as text' \
        | grep -Fxq -- "$1"
}

# next_file_selects_main: View > Next File on the changeset window selects
# main.swift. When Prism is in the background (PRISM_TESTING keeps it
# there) the menu item is disabled, so the next row of the sidebar is
# selected through Accessibility instead: the table whose AXIdentifier is
# prism.changeset.files (row 1 is the "Root Path" group, rows 2-4 are
# conf.ini, main.swift, notes.txt), by setting AXSelected on row 3.
next_file_selects_main() {
    if ax_menu_enabled View "Next File"; then
        ax_menu View "Next File" || return 1
        wait_until 5 perf_has changesetSelection "d['relativePath'] == 'main.swift'" && return 0
    fi
    echo "View > Next File is not available in the background; selecting the row through AX"
    ax_bg 'set w to window "Changes in repo"' \
        'set candidates to {}' \
        'repeat with sa in (scroll areas of w)' \
        '  set candidates to candidates & (tables of sa)' \
        'end repeat' \
        'repeat with g in (groups of w)' \
        '  repeat with sa in (scroll areas of g)' \
        '    set candidates to candidates & (tables of sa)' \
        '  end repeat' \
        'end repeat' \
        'set sidebar to missing value' \
        'repeat with t in candidates' \
        '  try' \
        '    if (value of attribute "AXIdentifier" of t) is "prism.changeset.files" then set sidebar to contents of t' \
        '  end try' \
        'end repeat' \
        'if sidebar is missing value then error "changeset sidebar table not found"' \
        'set value of attribute "AXSelected" of row 3 of sidebar to true' >/dev/null || return 1
    wait_until 5 perf_has changesetSelection "d['relativePath'] == 'main.swift'"
}

# wait_until_cmd_w: prism --wait blocks until File > Close (Cmd-W) closes
# the window.
wait_until_cmd_w() {
    local pid status=0
    "$prism_bin" --wait --label "Waiting comparison" "$FIX_B" "$FIX_A" &
    pid=$!
    wait_until 10 ax_window_named "Waiting comparison" || { echo "no window 'Waiting comparison'"; kill "$pid"; return 1; }
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || { echo "prism --wait returned before the close"; return 1; }
    # File > Close (Cmd-W), pressed through Accessibility on that window.
    # File > Close is disabled while Prism is in the background; the
    # window's own close button (subrole AXCloseButton) closes it the same
    # way (performClose).
    if ax_menu_enabled File "Close"; then
        ax_menu File "Close" || { kill "$pid"; return 1; }
    else
        echo "File > Close is not available in the background; pressing the window's close button"
        ax_bg 'set w to window "Waiting comparison"' \
            'perform action "AXPress" of (first button of w whose subrole is "AXCloseButton")' >/dev/null \
            || { kill "$pid"; return 1; }
    fi
    wait_until 5 window_gone "Waiting comparison" || { echo "window still open"; kill "$pid"; return 1; }
    wait "$pid" || status=$?
    echo "prism --wait exited $status after Cmd-W"
    (( status == 0 ))
}

# window_gone <title>: our app is running and shows no window with that title.
window_gone() {
    app_running && ! _app_windows | awk -F'\t' -v t="$1" '$2 == 0 && $5 == t { found = 1 } END { exit !found }'
}

two_changeset_windows() {
    changeset_window "Changes in c1" "$RUN1" && changeset_window "Changes in c2" "$RUN2"
}

# killed_real_app_exits_one: prism -w on a new document, SIGKILL to our
# app, and prism exits 1 within 100 ms. Deterministic and bounded:
#   - the app PID is our build's (checked), never empty;
#   - prism cannot start another app (PRISM_APP_PATH points nowhere);
#   - the document is known to be open (server status) before the kill;
#   - prism's exit time is recorded by a wrapper, so no wait without a
#     limit (and no zombie confusing a kill -0 poll).
killed_real_app_exits_one() {
    local app before pid done_file="$SCRATCH/kill-wait.done" kill_ms exit_ms rc
    app=$(app_pid) || { echo "our app is not running"; return 1; }
    before=$(status_json | grep -c '"id"')
    rm -f "$done_file"
    (
        PRISM_APP_PATH="$SCRATCH/no-such/Prism.app" "$prism_bin" -w --label "Kill test" "$FIX_A" "$FIX_B" 2>/dev/null
        rc=$?
        echo "$rc $(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time * 1000')" > "$done_file"
    ) &
    pid=$!
    if ! wait_until 10 bash -c "(( \$('$STUB' status --socket '$APP_SOCKET' | grep -c '\"id\"') > $before ))"; then
        echo "the document never opened"
        kill_tree "$pid"
        return 1
    fi
    [[ -f "$done_file" ]] && { echo "prism -w returned early: $(cat "$done_file")"; return 1; }
    kill_ms=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
    kill -KILL "$app"
    if ! wait_until 5 test -s "$done_file"; then
        echo "prism -w still waiting 5 s after the app was killed"
        kill_tree "$pid"
        return 1
    fi
    wait "$pid" 2>/dev/null
    read -r rc exit_ms < "$done_file"
    wait_until 5 _app_gone "$app"
    ACCEPT_APP_PID=""
    echo "prism exit status $rc, $((exit_ms - kill_ms)) ms after the kill"
    (( rc == 1 && exit_ms - kill_ms < 100 ))
}

warm_round_trip_app() {
    local json median
    json=$("$STUB" bench --socket "$APP_SOCKET" --count 500 --op mark) || return 1
    echo "$json"
    median=$(/usr/bin/python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["median_ms"])' "$json")
    /usr/bin/python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 1.0 else 1)' "$median"
}

# app_quit_and_forget: lib.sh app_quit for the running instance (the PID is
# re-read: checks run in subshells).
app_quit_and_forget() {
    ACCEPT_APP_PID=$(app_pid 2>/dev/null || true)
    app_quit
}

# --- Integration window ---

INTEG="$SCRATCH/integ"
FOREIGN_APP="$SCRATCH/Applications/Other Tool.app"

# integration_launch: our app with every install redirected to $INTEG.
integration_launch() {
    rm -rf "$INTEG" "$SCRATCH/Applications"
    mkdir -p "$INTEG/bin" "$FOREIGN_APP/Contents/Resources/bin"
    printf '#!/bin/sh\necho other tool\n' > "$FOREIGN_APP/Contents/Resources/bin/prism"
    chmod +x "$FOREIGN_APP/Contents/Resources/bin/prism"
    ln -s "$FOREIGN_APP/Contents/Resources/bin/prism" "$INTEG/bin/prism"
    printf '[user]\n\tname = Someone\n[diff]\n\ttool = vimdiff\n' > "$INTEG/gitconfig"
    cp "$INTEG/gitconfig" "$SCRATCH/gitconfig.before"
    open -n -g "$ACCEPT_APP" --env "PRISM_TESTING=1" --env "PRISM_INTEGRATION_ROOT=$INTEG" --env "PRISM_SOCKET_PATH=$APP_SOCKET" \
        --env "PRISM_SHOW_ABOUT=0" --env "PRISM_PERF_LOG=$APP_PERF" || return 1
    wait_until 15 app_pid || return 1
    ACCEPT_APP_PID=$(app_pid)
    ax_menu Prism "Integration…" || return 1
    wait_until 10 ax_window_named Integration
}

integ_ax() {      # integ_ax <applescript lines...> inside our process
    ax_bg "$@"
}

install_shows_conflict_choice() {
    local buttons
    integ_ax 'click button "Install…" of window "Integration"' >/dev/null || return 1
    sleep 1
    buttons=$(integ_ax 'get name of every button of sheet 1 of window "Integration"') || return 1
    echo "sheet buttons: $buttons"
    [[ "$buttons" == "Install as prism-diff, Cancel" ]]
}

installs_as_alternate() {
    integ_ax 'click button "Install as prism-diff" of sheet 1 of window "Integration"' >/dev/null || return 1
    wait_until 5 test -L "$INTEG/bin/prism-diff" || { ls -l "$INTEG/bin"; return 1; }
    ls -l "$INTEG/bin"
    [[ "$(readlink "$INTEG/bin/prism")" == "$FOREIGN_APP/Contents/Resources/bin/prism" ]] \
        && [[ "$(readlink "$INTEG/bin/prism-diff")" == "$ACCEPT_APP/Contents/Helpers/prism" ]]
}

remove_then_install_silently() {
    integ_ax 'click button "Remove…" of window "Integration"' >/dev/null || return 1
    wait_until 5 bash -c "[[ ! -e '$INTEG/bin/prism-diff' ]]" || { echo "prism-diff not removed"; return 1; }
    # The other application's prism is left alone; take it away by hand.
    [[ -L "$INTEG/bin/prism" ]] || { echo "foreign prism was touched"; return 1; }
    rm -f "$INTEG/bin/prism"
    integ_ax 'click button "Install…" of window "Integration"' >/dev/null || return 1
    sleep 1
    local sheets
    sheets=$(integ_ax 'count sheets of window "Integration"') || return 1
    echo "sheets after Install: $sheets"
    [[ "$sheets" == 0 ]] && [[ "$(readlink "$INTEG/bin/prism")" == "$ACCEPT_APP/Contents/Helpers/prism" ]]
}

git_install_writes_cmd() {
    integ_ax 'select row 2 of table 1 of scroll area 1 of window "Integration"' >/dev/null || return 1
    sleep 1
    echo "buttons: $(integ_ax 'get name of every button of window "Integration"')"
    integ_ax 'click button "Install" of window "Integration"' >/dev/null || return 1
    sleep 1
    cat "$INTEG/gitconfig"
    local cmd tool
    cmd=$(GIT_CONFIG_GLOBAL="$INTEG/gitconfig" git config --global --get difftool.prism.cmd)
    tool=$(GIT_CONFIG_GLOBAL="$INTEG/gitconfig" git config --global --get diff.tool)
    [[ "$cmd" == "$INTEG/bin/prism --partial-changeset --relative-path \"\$MERGED\" -- \"\$LOCAL\" \"\$REMOTE\"" \
        && "$tool" == prism ]]
}

git_remove_restores() {
    integ_ax 'click button "Remove" of window "Integration"' >/dev/null || return 1
    sleep 1
    cmp "$INTEG/gitconfig" "$SCRATCH/gitconfig.before"
}

echo "-- 9. the app (build/Prism.app)"
if [[ "${CI:-}" == "true" || "${PRISM_ACCEPT_NO_APP:-}" == 1 ]]; then
    echo "notice: app section skipped (CI or PRISM_ACCEPT_NO_APP=1)"
else
    check "scripts/bundle.sh builds build/Prism.app" scripts/bundle.sh
    prism_bin="$ACCEPT_APP/Contents/Helpers/prism"
    use_app
    echo "   waiting for the GUI lock"
    if ! check "GUI lock acquired (gives up after ${PRISM_GUI_LOCK_TIMEOUT:-600} s)" gui_lock; then
        echo "notice: app section skipped: no GUI lock"
    else
    app_check 960 "no other Prism instance is running (waits up to 15 min)" wait_for_other_prisms
    app_check 30 "no instance of build/Prism.app is running" no_app_running
    app_check 60 "cold start: prism a b -> comparison drawn within 1 s" cold_start
    app_check 30 "started by prism: the comparison is the only window" only_window
    app_check 60 "warm round trip with the app, median <= 1 ms" warm_round_trip_app
    configure_difftool
    app_check 60 "git difftool -y -t prism (3 files) against the app: each call exits 0 at once" difftool_three
    app_check 30 "the app holds one changeset 'Changes in repo' with 3 rows" three_rows_one_changeset
    app_check 30 "one window 'Changes in repo' with 3 sidebar rows" changeset_window "Changes in repo" 3
    if gui_available; then
        app_check 30 "capture the changeset window (compare with screen 20)" capture changeset "Changes in repo"
        app_check 60 "View > Next File (Shift-Cmd-Down) selects the next file (main.swift)" next_file_selects_main
        app_check 60 "prism --wait blocks until File > Close (Cmd-W), then exits 0" wait_until_cmd_w
    else
        echo "notice: no UI scripting: capture, Shift-Cmd-Down and Cmd-W skipped"
    fi
    app_check 600 "git difftool over $BIG files against the app: every call exits 0" difftool_big
    app_check 30 "one changeset window with $BIG sidebar rows" changeset_window "Changes in big" "$BIG"
    app_check 600 "two concurrent runs against the app ($RUN1 + $RUN2)" difftool_concurrent
    app_check 30 "two changeset windows, $RUN1 and $RUN2 rows" two_changeset_windows
    app_check 30 "no prism process left" no_client_left
    app_check 60 "app killed during prism -w: exit 1 within 100 ms" killed_real_app_exits_one
    if gui_available; then
        app_check 60 "Integration window opens from Prism > Integration…" integration_launch
        app_check 30 "capture the Integration window (compare with screen 36)" capture integration Integration
        app_check 60 "foreign prism: Install offers prism-diff or Cancel" install_shows_conflict_choice
        app_check 60 "Install as prism-diff leaves the foreign prism alone" installs_as_alternate
        app_check 60 "with no foreign prism, Install installs without asking" remove_then_install_silently
        app_check 60 "Git > Install writes difftool.prism.cmd and diff.tool" git_install_writes_cmd
        app_check 60 "Git > Remove restores the gitconfig byte for byte" git_remove_restores
        dismiss_sheets >/dev/null 2>&1 || true
    else
        echo "notice: no UI scripting: Integration window checks skipped"
    fi
    check "quit Prism.app" timed 60 app_quit_and_forget
    gui_unlock
    fi
fi

accept_summary
