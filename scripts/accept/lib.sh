# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Shared helpers for the milestone acceptance scripts (scripts/accept/M*.sh).
# Source it, call accept_init, run checks, end with accept_summary:
#
#   source "$(dirname "$0")/lib.sh"
#   accept_init M00
#   check "bundle exists" test -d "$ACCEPT_APP"
#   accept_summary
#
# Results are printed as plain ASCII "PASS"/"FAIL" lines. Output of each
# check goes to build/accept/<milestone>/checks.log.
#
# App helpers drive our own build/Prism.app only: they never touch any other
# application, and app_quit / the exit trap only stop the process this
# script launched (by PID), never another copy with the same bundle id.
#
# GUI helpers (ax_*, app_key) use System Events and need the Accessibility
# permission. gui_available returns false when CI=true or when UI scripting
# is not allowed, so scripts can fall back to headless checks.

# Refuse to run as a script: the helpers modify the caller's shell state.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "lib.sh: source this file, do not execute it" >&2
    exit 2
fi

ACCEPT_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
readonly ACCEPT_ROOT
readonly ACCEPT_BUNDLE_ID=io.github.pditommaso.prism
# Apps launched by acceptance scripts (open passes this environment on)
# never bring themselves to the front and accept test-only overrides.
export PRISM_TESTING=1
readonly ACCEPT_PROCESS_NAME=Prism
ACCEPT_APP="${ACCEPT_APP:-$ACCEPT_ROOT/build/Prism.app}"
ACCEPT_EXEC="$ACCEPT_APP/Contents/MacOS/Prism"
ACCEPT_WINLIST="$ACCEPT_ROOT/build/tools/winlist"
ACCEPT_KEYPOST="$ACCEPT_ROOT/build/tools/keypost"

ACCEPT_MILESTONE=""
ACCEPT_DIR=""
ACCEPT_LOG=/dev/null
ACCEPT_PASS=0
ACCEPT_FAIL=0
ACCEPT_FAILED_CHECKS=()
ACCEPT_APP_PID=""
ACCEPT_GUI_CACHE=""

# --- bookkeeping -----------------------------------------------------------

# accept_init <milestone>: prepares build/accept/<milestone>/, resets the
# counters and installs a trap that quits the app on exit or interrupt.
accept_init() {
    [[ $# -eq 1 && -n "$1" ]] || { echo "usage: accept_init <milestone>" >&2; return 2; }
    ACCEPT_MILESTONE="$1"
    ACCEPT_DIR="$ACCEPT_ROOT/build/accept/$1"
    mkdir -p "$ACCEPT_DIR"
    ACCEPT_LOG="$ACCEPT_DIR/checks.log"
    : > "$ACCEPT_LOG"
    ACCEPT_PASS=0
    ACCEPT_FAIL=0
    ACCEPT_FAILED_CHECKS=()
    # Window restoration (M10) reads and writes this file, never the
    # user's saved windows: under PRISM_TESTING=1 the app has no state file
    # unless PRISM_STATE_PATH names one. Scripts may point it elsewhere.
    export PRISM_STATE_PATH="${PRISM_STATE_PATH:-$ACCEPT_DIR/windows-state.json}"
    rm -f "$PRISM_STATE_PATH"
    trap accept_cleanup EXIT
    trap 'accept_cleanup; exit 130' INT TERM
    echo "== acceptance $1 ($(gui_available && echo gui || echo headless) mode)"
}

# Exit trap: makes sure no app instance launched by this script survives.
# An instance this script did not launch is left alone.
accept_cleanup() {
    if [[ -n "$ACCEPT_APP_PID" ]]; then
        app_quit >/dev/null 2>&1 || true
    fi
}

# check <description> <command...>: runs the command, records and prints
# PASS or FAIL. Never aborts the caller, even under `set -e`.
check() {
    local description="$1"; shift
    local status=0 start output
    start=$(wc -l < "$ACCEPT_LOG" 2>/dev/null || echo 0)
    {
        echo "--- $description"
        echo "\$ $*"
    } >> "$ACCEPT_LOG"
    "$@" >> "$ACCEPT_LOG" 2>&1 || status=$?
    if (( status == 0 )); then
        ACCEPT_PASS=$((ACCEPT_PASS + 1))
        printf 'PASS  %s\n' "$description"
    else
        ACCEPT_FAIL=$((ACCEPT_FAIL + 1))
        ACCEPT_FAILED_CHECKS+=("$description")
        printf 'FAIL  %s (exit %d)\n' "$description" "$status"
        # Show the tail of this check's output to make failures readable.
        output=$(tail -n +"$((start + 3))" "$ACCEPT_LOG" 2>/dev/null | tail -n 5)
        [[ -n "$output" ]] && sed 's/^/      /' <<<"$output"
    fi
    return 0
}

# accept_summary: prints the totals; exits 1 when any check failed, 0
# otherwise.
accept_summary() {
    local total=$((ACCEPT_PASS + ACCEPT_FAIL)) name
    echo "== $ACCEPT_MILESTONE: $ACCEPT_PASS/$total checks passed"
    if (( ACCEPT_FAIL > 0 )); then
        for name in "${ACCEPT_FAILED_CHECKS[@]}"; do
            echo "   failed: $name"
        done
        echo "== RESULT: FAIL (log: ${ACCEPT_LOG#"$ACCEPT_ROOT/"})"
        exit 1
    fi
    echo "== RESULT: PASS"
    exit 0
}

# --- utilities -------------------------------------------------------------

# with_timeout <seconds> <command...>: runs the command, killing it after
# the given number of seconds (perl alarm; no GNU coreutils needed).
with_timeout() {
    local seconds="$1"; shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$seconds" "$@"
}

# wait_until <timeout seconds> <command...>: polls every 0.25 s until the
# command succeeds. Returns 1 on timeout.
wait_until() {
    local timeout="$1"; shift
    local deadline=$((SECONDS + timeout))
    while true; do
        "$@" >/dev/null 2>&1 && return 0
        (( SECONDS >= deadline )) && return 1
        sleep 0.25
    done
}

# gui_available: true when UI scripting can be used (not CI, and System
# Events reports that Accessibility access is granted). Cached per run.
gui_available() {
    if [[ -z "$ACCEPT_GUI_CACHE" ]]; then
        ACCEPT_GUI_CACHE=no
        if [[ "${CI:-}" != "true" ]] && [[ "${PRISM_ACCEPT_HEADLESS:-}" != "1" ]]; then
            local enabled
            enabled=$(with_timeout 20 osascript -e \
                'tell application "System Events" to get UI elements enabled' 2>/dev/null || true)
            [[ "$enabled" == "true" ]] && ACCEPT_GUI_CACHE=yes
        fi
    fi
    [[ "$ACCEPT_GUI_CACHE" == yes ]]
}

# winlist [args]: our CGWindowList lister, compiled on first use (or when
# its source is newer than the binary) into build/tools/winlist.
winlist() {
    local source="$ACCEPT_ROOT/scripts/accept/tools/winlist.swift"
    if [[ ! -x "$ACCEPT_WINLIST" || "$source" -nt "$ACCEPT_WINLIST" ]]; then
        mkdir -p "$(dirname "$ACCEPT_WINLIST")"
        swiftc -O -swift-version 6 -o "$ACCEPT_WINLIST" "$source" 2>&1 \
            | grep -v "ld: warning: search path" >&2 || true
        [[ -x "$ACCEPT_WINLIST" ]] || { echo "winlist: build failed" >&2; return 2; }
    fi
    "$ACCEPT_WINLIST" "$@"
}

# --- app lifecycle ---------------------------------------------------------

# app_pid: PID of the Prism process running from our build/Prism.app (by
# exact executable path), or nothing.
app_pid() {
    local pid
    for pid in $(pgrep -x "$ACCEPT_PROCESS_NAME" 2>/dev/null); do
        if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$ACCEPT_EXEC" ]]; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

# app_launch [args...]: launches build/Prism.app as a new instance through
# Launch Services, waits up to 15 s for its process and records the PID
# in ACCEPT_APP_PID. Fails if an instance from this bundle already runs.
app_launch() {
    [[ -x "$ACCEPT_EXEC" ]] || { echo "app_launch: $ACCEPT_EXEC not found (run scripts/bundle.sh)" >&2; return 1; }
    if app_pid >/dev/null; then
        echo "app_launch: an instance of $ACCEPT_APP is already running" >&2
        return 1
    fi
    if (( $# > 0 )); then
        open -n "$ACCEPT_APP" --args "$@" || return 1
    else
        open -n "$ACCEPT_APP" || return 1
    fi
    if ! wait_until 15 app_pid; then
        echo "app_launch: Prism did not start within 15 s" >&2
        return 1
    fi
    ACCEPT_APP_PID=$(app_pid)
    echo "app_launch: pid $ACCEPT_APP_PID"
}

# app_running: true while the launched instance is alive.
app_running() {
    [[ -n "$(app_pid)" ]]
}

# app_arch: prints the architecture Launch Services reports for the running
# app (ARM64 for native Apple silicon, X86_64 under Rosetta).
app_arch() {
    local pid
    pid=$(app_pid) || { echo "app_arch: Prism is not running" >&2; return 1; }
    # Right after launch the app may not have checked in yet: retry briefly.
    local arch="" deadline=$((SECONDS + 10))
    while [[ -z "$arch" ]]; do
        arch=$(lsappinfo info "$pid" 2>/dev/null | grep -F "pid = $pid " \
            | grep -oE 'Arch=[A-Za-z0-9_]+' | head -n 1 | cut -d= -f2)
        [[ -n "$arch" ]] && break
        (( SECONDS >= deadline )) && { echo "app_arch: lsappinfo has no entry for pid $pid" >&2; return 1; }
        sleep 0.25
    done
    echo "$arch"
}

# app_is_native: true when app_arch is ARM64.
app_is_native() {
    local arch
    arch=$(app_arch) || return 1
    echo "arch: $arch"
    [[ "$arch" == "ARM64" ]]
}

# app_quit: asks the instance launched by app_launch (ACCEPT_APP_PID) to
# quit, addressing it by PID through NSRunningApplication so that another
# Prism copy with the same bundle id is never affected. Waits up to 10 s,
# then falls back to SIGTERM and SIGKILL of that PID only. Returns 0 once
# that process is gone (or when nothing was launched).
app_quit() {
    local pid="$ACCEPT_APP_PID"
    [[ -n "$pid" ]] || return 0
    _app_gone "$pid" && { ACCEPT_APP_PID=""; return 0; }
    with_timeout 15 osascript -l JavaScript \
        -e 'ObjC.import("AppKit")' \
        -e "var app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid)" \
        -e 'if (app && !app.isNil()) { app.terminate }' >/dev/null 2>&1 || true
    if ! wait_until 10 _app_gone "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        if ! wait_until 5 _app_gone "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
            wait_until 5 _app_gone "$pid" || return 1
        fi
    fi
    ACCEPT_APP_PID=""
    return 0
}

_app_gone() {
    ! kill -0 "$1" 2>/dev/null
}

# app_wait_window <title> [timeout seconds, default 10]: waits until our app
# shows a window with exactly that title. Uses System Events in GUI mode and
# the window server list otherwise.
app_wait_window() {
    local title="$1" timeout="${2:-10}"
    wait_until "$timeout" _app_has_window "$title"
}

# app_window_closed <title> (GUI mode): our app is still running, answers
# the window query and lists no window with that title. A failed query (the
# app crashed or quit, osascript error) is a failure, never an empty list.
app_window_closed() {
    local titles
    app_running || { echo "app is not running"; return 1; }
    titles=$(ax_window_titles) || { echo "window query failed"; return 1; }
    ! grep -Fxq -- "$1" <<<"$titles"
}

_app_has_window() {
    if gui_available; then
        ax_window_titles | grep -Fxq -- "$1"
    else
        _app_windows | awk -F'\t' -v t="$1" '$2 == 0 && $5 == t { found = 1 } END { exit !found }'
    fi
}

# _app_windows: winlist lines for windows owned by our app's PID.
_app_windows() {
    local pid
    pid=$(app_pid) || return 1
    winlist "$ACCEPT_PROCESS_NAME" | awk -F'\t' -v p="$pid" '$4 == p'
}

# app_window_id [title]: id of our app's first normal-layer window, or of
# the one with the given title.
app_window_id() {
    local title="${1:-}"
    _app_windows | awk -F'\t' -v t="$title" \
        '$2 == 0 && (t == "" || $5 == t) { print $1; found = 1; exit } END { exit !found }'
}

# capture <name> [window title]: screenshots one of our app's windows,
# without shadow, to build/accept/<milestone>/<name>.png.
capture() {
    local name="$1" title="${2:-}" id file
    [[ -n "$ACCEPT_DIR" ]] || { echo "capture: call accept_init first" >&2; return 2; }
    id=$(app_window_id "$title") || { echo "capture: no Prism window${title:+ titled '$title'}" >&2; return 1; }
    file="$ACCEPT_DIR/$name.png"
    rm -f "$file"
    screencapture -x -o -l "$id" "$file" || return 1
    [[ -s "$file" ]] || { echo "capture: $file is empty" >&2; return 1; }
    echo "captured ${file#"$ACCEPT_ROOT/"}"
}

# --- UI scripting (System Events) -------------------------------------------

# _ax <applescript lines...>: runs the lines inside a `tell` block for our
# app's process (matched by PID), after bringing it to the front.
_ax() {
    local pid
    pid=$(app_pid) || { echo "ax: Prism is not running" >&2; return 1; }
    local args=(-e 'tell application "System Events"'
                -e "set prismProcess to first process whose unix id is $pid"
                -e 'set frontmost of prismProcess to true'
                -e 'tell prismProcess')
    local line
    for line in "$@"; do args+=(-e "$line"); done
    args+=(-e 'end tell' -e 'end tell')
    with_timeout 20 osascript "${args[@]}"
}

# Quotes a string as an AppleScript string literal.
_as_string() {
    local s="${1//\\/\\\\}"
    printf '"%s"' "${s//\"/\\\"}"
}

# ax_click_menu <menu> <item>: clicks a menu bar item, e.g.
#   ax_click_menu Prism "About Prism"
ax_click_menu() {
    [[ $# -eq 2 ]] || { echo "usage: ax_click_menu <menu> <item>" >&2; return 2; }
    local menu item
    menu=$(_as_string "$1")
    item=$(_as_string "$2")
    _ax "click menu item $item of menu $menu of menu bar item $menu of menu bar 1" >/dev/null
}

# keypost [args]: our PID-targeted key poster, compiled on first use (or
# when its source is newer than the binary) into build/tools/keypost.
keypost() {
    local source="$ACCEPT_ROOT/scripts/accept/tools/keypost.swift"
    if [[ ! -x "$ACCEPT_KEYPOST" || "$source" -nt "$ACCEPT_KEYPOST" ]]; then
        mkdir -p "$(dirname "$ACCEPT_KEYPOST")"
        swiftc -O -swift-version 6 -o "$ACCEPT_KEYPOST" "$source" 2>&1 \
            | grep -v "ld: warning: search path" >&2 || true
        [[ -x "$ACCEPT_KEYPOST" ]] || { echo "keypost: build failed" >&2; return 2; }
    fi
    "$ACCEPT_KEYPOST" "$@"
}

# app_key <virtual key code> [cmd|shift|opt|ctrl...]: sends one key press
# to our app, e.g. `app_key 13 cmd` for Cmd-W. It first brings Prism to the
# front (waiting up to 5 s) so that it has a key window, then posts the
# event to Prism's PID only. Keys are never typed with System Events
# `keystroke`, which goes to whatever app is frontmost at that instant: if
# macOS activates another app in between, the press still reaches Prism
# (and at worst does nothing), never the other application.
app_key() {
    [[ $# -ge 1 ]] || { echo "usage: app_key <key code> [modifier...]" >&2; return 2; }
    local pid
    pid=$(app_pid) || { echo "app_key: Prism is not running" >&2; return 1; }
    _ax 'set waited to 0' \
        'repeat while (frontmost is false) and (waited < 50)' \
        'delay 0.1' \
        'set frontmost to true' \
        'set waited to waited + 1' \
        'end repeat' \
        'if frontmost is false then error "Prism did not become frontmost"' \
        'delay 0.2' >/dev/null || return 1
    keypost "$pid" "$@"
}

# ax_window_titles: titles of our app's windows, one per line.
ax_window_titles() {
    _ax 'set titles to name of every window' \
        'set AppleScript'"'"'s text item delimiters to linefeed' \
        'return titles as text'
}

# accept_tool <name> [args]: runs scripts/accept/tools/<name>.swift,
# compiled on first use (or when the source is newer) into build/tools/.
accept_tool() {
    local name="$1"; shift
    local source="$ACCEPT_ROOT/scripts/accept/tools/$name.swift"
    local binary="$ACCEPT_ROOT/build/tools/$name"
    [[ -f "$source" ]] || { echo "accept_tool: no tool named $name" >&2; return 2; }
    if [[ ! -x "$binary" || "$source" -nt "$binary" ]]; then
        mkdir -p "$(dirname "$binary")"
        swiftc -O -swift-version 6 -o "$binary" "$source" 2>&1 \
            | grep -v "ld: warning: search path" >&2 || true
        [[ -x "$binary" ]] || { echo "accept_tool: $name build failed" >&2; return 2; }
    fi
    "$binary" "$@"
}
