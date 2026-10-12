#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M4 (full text viewing: Fluid, Unified,
# find, ignore whitespace, wrap lines). Exit status: 0 when every check
# passes, 1 otherwise.
#
#   scripts/accept/M04.sh             local run; GUI mode when Accessibility
#                                     is granted (keys, AX reads, captures, OCR)
#   CI=true scripts/accept/M04.sh     headless mode: the same behaviours through
#                                     the app's perf log and debug hooks
#                                     (missed-frame budgets not judged)
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (the unit
#                               tests of the app still run)
#   PRISM_PERF_SCALE=<factor>   multiplies the time budgets (default 1)
#   PRISM_ACCEPT_HEADLESS=1     force headless mode locally
#
# The layout is remembered in the app's user defaults; the script saves the
# value it finds and puts it back when it exits.
#
# Mapping of the MILESTONES.md M4 acceptance bullets to sections below:
#   Fluid and Unified match screens 01 and 03, find matches 08  -> 3, 4, 5 (captures in
#                                                                  build/accept/M04/ for review)
#   "name" in a.swift: "1st of 4 results in A (5 more in B)"     -> 5
#   ignore whitespace on the indent-only fixture: 0 changes     -> 6
#   wrap on big_a/big_b at 600 pt: aligned after 3 resizes,    -> 7
#     <= 5 missed frames
#   VoiceOver (AX) reads the focused line's text and number    -> 8
#   quit in Unified, relaunch, a new pair opens in Unified      -> 9
#   carry-over: a 5 MB single line scrolls without stalls       -> 10
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M04

readonly TEXT="$ACCEPT_ROOT/Tests/corpus/fixtures/text"
readonly CORPUS="$ACCEPT_ROOT/Tests/corpus"
readonly GENERATED="$CORPUS/generated"
SCALE="${PRISM_PERF_SCALE:-1}"
readonly SCALE
PERF="$ACCEPT_DIR/perf.log"
readonly PERF
readonly MODE_KEY=prism.text.viewMode

# --- remembered layout: save now, restore on exit ----------------------------------
SAVED_MODE=$(defaults read "$ACCEPT_BUNDLE_ID" "$MODE_KEY" 2>/dev/null || true)
m04_restore_defaults() {
    if [[ -n "$SAVED_MODE" ]]; then
        defaults write "$ACCEPT_BUNDLE_ID" "$MODE_KEY" -string "$SAVED_MODE"
    else
        defaults delete "$ACCEPT_BUNDLE_ID" "$MODE_KEY" >/dev/null 2>&1 || true
    fi
}
trap 'accept_cleanup; m04_restore_defaults' EXIT
trap 'accept_cleanup; m04_restore_defaults; exit 130' INT TERM

# --- helpers -------------------------------------------------------------------

# m04_launch [VAR=value...] -- [app arguments...]: launches build/Prism.app
# through Launch Services with a fresh perf log and the given environment.
m04_launch() {
    local envs=(--env "PRISM_PERF_LOG=$PERF")
    while (( $# > 0 )) && [[ "$1" != "--" ]]; do envs+=(--env "$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    : > "$PERF"
    if app_pid >/dev/null; then
        echo "m04_launch: an instance of $ACCEPT_APP is already running" >&2
        return 1
    fi
    open -n "${envs[@]}" "$ACCEPT_APP" --args "$@" || return 1
    wait_until 15 app_pid || { echo "m04_launch: Prism did not start" >&2; return 1; }
    ACCEPT_APP_PID=$(app_pid)
    echo "launched pid $ACCEPT_APP_PID: $*"
}

# perf_field <event> <python expression over d>: the value for the last
# event of that name (empty when there is none).
perf_field() {
    /usr/bin/python3 -I - "$PERF" "$1" "$2" <<'PY'
import json, sys
path, name, expr = sys.argv[1:4]
last = None
try:
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("event") == name:
            last = d
except OSError:
    pass
if last is not None:
    value = eval(expr, {}, {"d": last})
    print(json.dumps(value) if not isinstance(value, str) else value)
PY
}

has_event() { [[ -n "$(perf_field "$1" 'd["event"]')" ]]; }
wait_event() { wait_until "${2:-20}" has_event "$1"; }
show_event() { perf_field "$1" 'd'; }

expect_perf() {
    local result
    result=$(perf_field "$1" "$2")
    echo "$1: $2 -> ${result:-<no event>}"
    [[ "$result" == "true" ]]
}

# field_is <event> <key> <text>: the last event has that string value.
field_is() {
    local value
    value=$(perf_field "$1" "d.get('$2', '')")
    echo "$1.$2: ${value:-<none>}"
    [[ "$value" == "$3" ]]
}

wait_field() { wait_until "${4:-10}" field_is "$1" "$2" "$3"; }

budget() { /usr/bin/python3 -I -c "print($1 * $SCALE)"; }

# keys <code...>: plain key presses posted to Prism, e.g. letters of a word
# (used only where no menu or button does the job: typing, Down, Escape).
keys() {
    local code
    for code in "$@"; do
        app_key "$code" || return 1
        sleep 0.08
    done
}

# ax_texts: every static text and button title of the front window.
ax_texts() {
    _ax 'set out to ""' \
        'set elems to (every static text of window 1) & (every button of window 1)' \
        'repeat with i from 1 to count of elems' \
        'try' \
        'set v to value of (item i of elems)' \
        'if v is missing value then set v to title of (item i of elems)' \
        'set out to out & (v as text) & linefeed' \
        'end try' \
        'end repeat' \
        'return out'
}

ax_has_text() {
    local texts
    texts=$(ax_texts) || return 1
    grep -Fxq -- "$1" <<<"$texts" && { echo "AX shows: $1"; return 0; }
    echo "AX texts:"; echo "$texts" | head -20
    return 1
}

# ax_focused_line: label and value of the focused accessibility element.
ax_focused_line() {
    _ax 'set f to value of attribute "AXFocusedUIElement"' \
        'return (value of attribute "AXDescription" of f) & "|" & (value of attribute "AXValue" of f)'
}

focused_line_is() {
    local line
    line=$(ax_focused_line) || return 1
    echo "focused: $line"
    [[ "$line" == "$1" ]]
}

# ocr_aligned <shot>: every text row that OCR reads as "line N:" in the left
# pane has the same N in the right pane at the same height.
ocr_aligned() {
    local rows
    rows=$(accept_tool ocrrows "$1") || return 1
    /usr/bin/python3 -I - "$rows" <<'PY'
import re, sys
runs = []
for line in sys.argv[1].splitlines():
    parts = line.split("\t", 3)
    if len(parts) == 4:
        runs.append((float(parts[0]), float(parts[1]), parts[3]))
if not runs:
    print("no text recognized"); raise SystemExit(1)
mid = (max(r[1] for r in runs) + min(r[1] for r in runs)) / 2
def rows_of(pane):
    rows = []
    for y, x, text in sorted(pane):
        if rows and abs(rows[-1][0] - y) <= 6:
            rows[-1][1].append((x, text))
        else:
            rows.append([y, [(x, text)]])
    out = []
    for y, parts in rows:
        joined = " ".join(t for _, t in sorted(parts))
        m = re.search(r"line\s*(\d+)\s*:", joined)
        if m:
            out.append((y, int(m.group(1))))
    return out
left = rows_of([r for r in runs if r[1] < mid])
right = rows_of([r for r in runs if r[1] >= mid])
pairs = matched = 0
for y, n in left:
    near = [m for (yy, m) in right if abs(yy - y) <= 6]
    if not near:
        continue
    pairs += 1
    matched += n in near
print(f"rows left={len(left)} right={len(right)} pairs={pairs} matched={matched}")
raise SystemExit(0 if pairs >= 8 and matched >= 0.9 * pairs else 1)
PY
}

# ax_find_menu <item>: clicks Edit > Find > <item> through Accessibility.
ax_find_menu() {
    local item
    item=$(_as_string "$1")
    _ax "click menu item $item of menu \"Find\" of menu item \"Find\" of menu \"Edit\" of menu bar item \"Edit\" of menu bar 1" >/dev/null
}

# capture_retry <name>: capture, retried briefly (the window server may
# still be settling after a resize).
capture_retry() {
    local _attempt
    for _attempt in 1 2 3 4 5; do
        capture "$1" && return 0
        sleep 1
    done
    return 1
}

generated_ok() {
    (cd "$GENERATED" && shasum -a 256 -c ../generated.sha256 --quiet)
}

# --- 1. guards -------------------------------------------------------------------
echo "-- 1. guards"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
if git rev-parse -q --verify 'master^{commit}' >/dev/null; then
    check "DCO sign-off (check-dco.sh master..HEAD)" scripts/ci/check-dco.sh master..HEAD
fi

# --- 2. build, tests, bundle and inputs ------------------------------------------------
echo "-- 2. build, tests, bundle and inputs"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
    check "app unit tests (layouts, wrap, find, selection, AX, carry-overs)" swift test --filter PrismAppTests
else
    check "release build zero warnings + swift test (build-strict.sh)" scripts/ci/build-strict.sh
fi
check "scripts/bundle.sh succeeds" scripts/bundle.sh
if ! generated_ok >/dev/null 2>&1; then
    check "generate the large corpus inputs (generate.py)" /usr/bin/python3 -I "$CORPUS/scripts/generate.py"
fi
check "generated inputs match generated.sha256" generated_ok

# --- 3. Fluid ----------------------------------------------------------------------
echo "-- 3. Fluid (screen 01)"
check "launch a.swift b.swift in Fluid" m04_launch -- -$MODE_KEY fluid "$TEXT/a.swift" "$TEXT/b.swift"
check "first paint in Fluid, 8 changes" wait_event firstPaint 15
check "Fluid layout, 8 changes" expect_perf firstPaint 'd["mode"] == "fluid" and d["changes"] == 8'
if gui_available; then
    check "capture Fluid (compare with screen 01)" capture fluid-light
    check "View > Next Change in Fluid" ax_click_menu View "Next Change"
    check "perf log: Change 2 of 8" wait_field selection label "Change 2 of 8" 5
fi
check "quit" app_quit

# --- 4. Unified ----------------------------------------------------------------------
echo "-- 4. Unified (screen 03)"
check "launch a.swift b.swift in Unified" m04_launch -- -$MODE_KEY unified "$TEXT/a.swift" "$TEXT/b.swift"
check "first paint in Unified" wait_event firstPaint 15
check "Unified layout, 8 changes" expect_perf firstPaint 'd["mode"] == "unified" and d["changes"] == 8'
if gui_available; then
    check "capture Unified (compare with screen 03)" capture unified-light
fi
check "quit" app_quit
for theme in "dark-multicolor:-prism.text.dark YES -prism.text.singleColor NO:fluid:33" \
             "light-single:-prism.text.dark NO -prism.text.singleColor YES:unified:35"; do
    IFS=: read -r name defaults mode screen <<<"$theme"
    # shellcheck disable=SC2086  # the defaults are separate words on purpose
    check "launch $mode in $name" m04_launch -- $defaults -$MODE_KEY "$mode" "$TEXT/a.swift" "$TEXT/b.swift"
    check "$mode $name: first paint" wait_event firstPaint 15
    if gui_available; then
        check "capture $mode $name (colours as in screen $screen)" capture "$mode-$name"
    fi
    check "quit" app_quit
done

# --- 5. find ---------------------------------------------------------------------------
echo "-- 5. find (screen 08)"
if gui_available; then
    check "launch a.swift b.swift in Blocks" m04_launch -- -$MODE_KEY blocks "$TEXT/a.swift" "$TEXT/b.swift"
    check "first paint" wait_event firstPaint 15
    check "window 'Prism' shown" app_wait_window "Prism" 10
    check "Edit > Find > Find... opens the find bar" ax_find_menu "Find…"
    sleep 0.4
    check "type 'name'" keys 45 0 46 14
    check "perf log: 1st of 4 results in A" wait_field find summary "1st of 4 results in A" 10
    check "perf log: (5 more in B)" field_is find note "(5 more in B)"
    check "find bar (Accessibility): 1st of 4 results in A" ax_has_text "1st of 4 results in A"
    check "find bar (Accessibility): (5 more in B)" ax_has_text "(5 more in B)"
    check "Edit > Find > Find Next" ax_find_menu "Find Next"
    check "perf log: 2nd of 4 results in A" wait_field find summary "2nd of 4 results in A" 5
    check "capture find (compare with screen 08)" capture find-blocks
    check "Close button closes the find bar" _ax 'click button "Close" of window 1'
    sleep 0.3
    check "find bar gone (Accessibility)" bash -c '! grep -Fxq "2nd of 4 results in A" <<<"$1"' _ "$(ax_texts)"
    check "quit" app_quit
else
    check "launch with a search for 'name' (debug hook)" \
        m04_launch PRISM_DEBUG_FIND=name -- -$MODE_KEY blocks "$TEXT/a.swift" "$TEXT/b.swift"
    check "perf log: 1st of 4 results in A" wait_field find summary "1st of 4 results in A" 15
    check "perf log: (5 more in B)" field_is find note "(5 more in B)"
    check "quit" app_quit
fi

# --- 6. ignore whitespace --------------------------------------------------------------
echo "-- 6. ignore whitespace on the indent-only pair"
check "launch ind_a ind_b" m04_launch -- -$MODE_KEY blocks "$GENERATED/ind_a.txt" "$GENERATED/ind_b.txt"
check "first paint" wait_event firstPaint 20
check "exact comparison shows changes" expect_perf firstPaint 'd["changes"] > 0 and not d["ignoreWhitespace"]'
if gui_available; then
    check "View > Ignore Whitespace" ax_click_menu View "Ignore Whitespace"
    check "perf log: No Changes after the re-diff" wait_field selection label "No Changes" 20
    check "bottom bar (Accessibility): No Changes" ax_has_text "No Changes"
    check "capture ignore whitespace (compare with screen 06)" capture ignore-whitespace
fi
check "quit" app_quit
check "launch ind pair with Ignore whitespace on" \
    m04_launch -- -$MODE_KEY blocks -prism.text.ignoreWhitespace YES "$GENERATED/ind_a.txt" "$GENERATED/ind_b.txt"
check "first paint" wait_event firstPaint 20
check "0 changes ignoring whitespace" expect_perf firstPaint 'd["changes"] == 0 and d["ignoreWhitespace"]'
check "quit" app_quit

# --- 7. wrap lines -----------------------------------------------------------------------
echo "-- 7. wrap on big_a / big_b, three resizes down to 600 pt"
check "launch big pair with the wrap bench" \
    m04_launch PRISM_BENCH_WRAP=1 -- -$MODE_KEY blocks "$TEXT/big_a.txt" "$TEXT/big_b.txt"
check "wrap bench finished" wait_event wrapBench 180
show_event wrapBench
check "window ends 600 pt wide, lines wrapped" expect_perf wrapBench 'd["windowWidth"] == 600 and d["wraps"]'
check "three resizes" expect_perf wrapBench 'len(d["resizes"]) == 3'
check "aligned after every resize" expect_perf wrapBench 'all(r["alignmentErrorPt"] == 0 for r in d["resizes"])'
check "aligned while scrolling at 600 pt" expect_perf wrapBench 'd["alignmentErrorMaxPt"] == 0'
if [[ "${CI:-}" == true ]]; then
    echo "notice: CI=true, missed-frame budgets not checked"
else
    check "resizes miss <= 5 frames in all" expect_perf wrapBench 'd["resizeMissedFrames"] <= 5'
    check "scrolling wrapped text at 600 pt misses <= 5 frames" expect_perf wrapBench 'd["scroll"]["missedFrames"] <= 5'
fi
if gui_available; then
    check "capture wrapped at 600 pt" capture_retry wrap-600
    check "OCR: wrapped A and B lines start at the same height" ocr_aligned "$ACCEPT_DIR/wrap-600.png"
fi
check "quit" app_quit

# --- 8. accessibility -------------------------------------------------------------------
echo "-- 8. accessibility of the lines"
if gui_available; then
    check "launch a.swift b.swift" m04_launch -- -$MODE_KEY blocks "$TEXT/a.swift" "$TEXT/b.swift"
    check "first paint" wait_event firstPaint 15
    check "window 'Prism' shown" app_wait_window "Prism" 10
    check "AX focused line: A line 1, import Foundation" wait_until 5 focused_line_is "A line 1|import Foundation"
    check "Down x3 moves the current line" keys 125 125 125
    check "AX focused line: A line 4, struct Greeter {" wait_until 5 focused_line_is "A line 4|struct Greeter {"
    check "quit" app_quit
else
    echo "notice: headless, AX reads covered by the unit tests only"
fi

# --- 9. the layout is remembered ----------------------------------------------------------
echo "-- 9. quit in Unified, relaunch"
defaults delete "$ACCEPT_BUNDLE_ID" "$MODE_KEY" >/dev/null 2>&1 || true
if gui_available; then
    check "launch a.swift b.swift" m04_launch -- "$TEXT/a.swift" "$TEXT/b.swift"
    check "first launch opens in Blocks" wait_field firstPaint mode blocks 15
    check "window 'Prism' shown" app_wait_window "Prism" 10
    check "View > Unified" ax_click_menu View Unified
    check "perf log: layout unified" wait_field layout mode unified 5
else
    check "launch, switch to Unified (debug hook)" \
        m04_launch PRISM_DEBUG_LAYOUT=unified -- "$TEXT/a.swift" "$TEXT/b.swift"
    check "first launch opens in Blocks" wait_field firstPaint mode blocks 15
    check "perf log: layout unified" wait_field layout mode unified 5
fi
check "quit in Unified" app_quit
check "relaunch with another pair" m04_launch -- "$TEXT/slider_a.groovy" "$TEXT/slider_b.groovy"
check "the new pair opens in Unified" wait_field firstPaint mode unified 15
check "quit" app_quit

# --- 10. carry-over: a very long line ------------------------------------------------------
echo "-- 10. a 5 MB single line"
check "launch min_a.json min_b.json with the scroll bench" \
    m04_launch PRISM_BENCH_SCROLL=1 -- -$MODE_KEY blocks "$GENERATED/min_a.json" "$GENERATED/min_b.json"
check "first paint" wait_event firstPaint 30
check "first paint <= $(budget 3000) ms after process start" \
    expect_perf firstPaint "d['sinceProcessStartMs'] <= $(budget 3000)"
check "scroll bench finished" wait_event scrollBench 120
show_event scrollBench
check "document width capped at 1,000,000 pt" expect_perf scrollBench 'd["documentWidth"] <= 1000000'
if [[ "${CI:-}" == true ]]; then
    echo "notice: CI=true, missed-frame budgets not checked"
else
    check "sideways sweep along the line misses <= 2 frames" \
        expect_perf scrollBench 'd["horizontal"]["missedFrames"] <= 2'
fi
check "quit" app_quit
check "no Prism.app process left" bash -c '! pgrep -f "$0" >/dev/null' "$ACCEPT_EXEC"

accept_summary
