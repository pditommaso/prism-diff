#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M3 (read-only two-pane text viewer,
# Blocks layout). Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/M03.sh             local run; GUI mode when Accessibility
#                                     is granted (keys, window drag, OCR)
#   CI=true scripts/accept/M03.sh     headless mode: perf, alignment and
#                                     scroll checks from the app's perf log
#                                     (missed-frame budgets not judged)
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (the unit
#                               tests of the app still run)
#   PRISM_PERF_SCALE=<factor>   multiplies the time budgets (default 1)
#   PRISM_ACCEPT_HEADLESS=1     force headless mode locally
#
# The app writes JSON lines to the file named by PRISM_PERF_LOG (events
# firstPaint, selection, placeholder, scrollBench); the checks read them.
#
# Mapping of the MILESTONES.md M3 acceptance bullets to sections below:
#   a.swift/b.swift Blocks matches screen 02 (8 changes,  -> 3 (8 changes, spacer rows and word
#     spacers, word highlights), dark multicolor (33)       highlights are unit-tested in
#     and light single color (35)                           PrismAppTests); screenshots for the
#                                                           visual review in build/accept/M03/
#   big pair: first paint <= 0.5 s, RSS <= 250 MB, UI      -> 4, 5
#     responsive during the diff (window drag)
#   jump to change 473 of 944, A and B aligned            -> 6 (perf log + OCR of a screenshot)
#   smooth-scroll stress misses <= 2 frames at 120 Hz      -> 7
#   Cmd-Down x3 shows "Change 4 of 8", band emphasised     -> 3
#   opening through Launch Services (open -a a b)          -> 8
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M03

readonly TEXT="$ACCEPT_ROOT/Tests/corpus/fixtures/text"
SCALE="${PRISM_PERF_SCALE:-1}"
readonly SCALE
PERF="$ACCEPT_DIR/perf.log"
readonly PERF

# --- helpers -------------------------------------------------------------------

# m03_launch [VAR=value...] -- [app arguments...]: launches build/Prism.app
# through Launch Services with a fresh perf log and the given environment.
m03_launch() {
    local envs=(--env "PRISM_PERF_LOG=$PERF")
    while (( $# > 0 )) && [[ "$1" != "--" ]]; do envs+=(--env "$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    : > "$PERF"
    if app_pid >/dev/null; then
        echo "m03_launch: an instance of $ACCEPT_APP is already running" >&2
        return 1
    fi
    # M3 checks the Blocks layout: pinned, whatever layout the app last used.
    open -n "${envs[@]}" "$ACCEPT_APP" --args -prism.text.viewMode blocks "$@" || return 1
    wait_until 15 app_pid || { echo "m03_launch: Prism did not start" >&2; return 1; }
    ACCEPT_APP_PID=$(app_pid)
    echo "launched pid $ACCEPT_APP_PID: $*"
}

# perf_field <event> <python expression over d> : prints the value for the
# last event of that name (empty when there is none).
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

wait_event() {       # wait_event <event> [timeout]
    wait_until "${2:-20}" has_event "$1"
}

# expect_perf <description-free> <event> <python condition over d>
expect_perf() {
    local result
    result=$(perf_field "$1" "$2")
    echo "$1: $2 -> ${result:-<no event>}"
    [[ "$result" == "true" ]]
}

show_event() { perf_field "$1" 'd'; }

# label_is <text>: the last selection event has that label.
label_is() {
    local label
    label=$(perf_field selection 'd["label"]')
    echo "label: ${label:-<none>}"
    [[ "$label" == "$1" ]]
}

# ax_change_label: the change label as Accessibility reports it.
ax_change_label() {
    _ax 'set out to ""' \
        'set texts to value of every static text of window 1' \
        'repeat with i from 1 to count of texts' \
        'try' \
        'set v to (item i of texts) as text' \
        'if v starts with "Change " or v is "No Changes" then set out to v' \
        'end try' \
        'end repeat' \
        'return out'
}

ax_label_is() {
    local label
    label=$(ax_change_label) || return 1
    echo "AX label: $label"
    [[ "$label" == "$1" ]]
}

# press_down <n>: Cmd-Down n times (key code 125), posted to Prism only.
press_down() {
    local i
    for (( i = 0; i < $1; i++ )); do
        app_key 125 cmd || return 1
        sleep 0.15
    done
}

# selected_band_emphasised <shot>: the selected change's line-number cell
# has the theme's selected colour in the screenshot (within a tolerance).
selected_band_emphasised() {
    local shot="$1" point color x y scale actual
    point=$(perf_field selection '" ".join(str(int(round(v))) for v in d["selectedGutterPoint"])') || return 1
    color=$(perf_field selection 'd["selectedGutterColor"]')
    read -r x y <<<"$point"
    scale=$(/usr/bin/python3 -I -c "
import subprocess,sys
w=int(subprocess.run(['sips','-g','pixelWidth','$shot'],capture_output=True,text=True).stdout.split()[-1])
print(round(w/1354))")
    actual=$(accept_tool pixel "$shot" $((x * scale)) $((y * scale))) || return 1
    echo "pixel at ($x,$y)x$scale: $actual, theme: $color"
    /usr/bin/python3 -I -c "
a='$actual'.lstrip('#'); b='$color'.lstrip('#')[:6]
d=max(abs(int(a[i:i+2],16)-int(b[i:i+2],16)) for i in (0,2,4))
print('max channel difference', d); raise SystemExit(0 if d <= 16 else 1)"
}

# move_window_during_load: while the diff is still running (artificially
# slowed), moves the window through Accessibility and reads the position
# back. A blocked main thread would time the request out.
move_window_during_load() {
    local before after start elapsed
    has_event firstPaint && { echo "the load already finished"; return 1; }
    before=$(_ax 'get position of window 1' | tr -d ' ')
    start=$(/usr/bin/python3 -I -c 'import time; print(time.time())')
    _ax 'set position of window 1 to {120, 90}' >/dev/null || return 1
    after=$(_ax 'get position of window 1' | tr -d ' ')
    elapsed=$(/usr/bin/python3 -I -c "import time; print(round((time.time() - $start) * 1000))")
    echo "position $before -> $after in ${elapsed} ms (load still running: $(has_event firstPaint && echo no || echo yes))"
    [[ "$after" == "120,90" ]] && (( elapsed < 2000 )) && ! has_event firstPaint
}

# ocr_aligned <shot>: in the screenshot, every text row that OCR reads as
# "line N:" in the left pane has the same N in the right pane at the same
# height, and the jump target (line 51895) is among them.
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
# OCR may split a row into several runs: group the runs of each pane into
# rows by height, join them left to right, then read "line N:".
mid = (max(r[1] for r in runs) + min(r[1] for r in runs)) / 2
def rows_of(pane):
    rows = []
    for y, x, text in sorted(pane):
        if rows and abs(rows[-1][0] - y) <= 8:
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
mismatches = []
for y, n in left:
    near = [m for (yy, m) in right if abs(yy - y) <= 8]
    if not near:
        continue
    pairs += 1
    if n in near:
        matched += 1
    else:
        mismatches.append((round(y), n, near))
target = any(n == 51895 for _, n in left) and any(n == 51895 for _, n in right)
print(f"rows left={len(left)} right={len(right)} pairs={pairs} matched={matched} target_visible={target}")
for m in mismatches[:10]:
    print("mismatch", m)
ok = pairs >= 20 and matched >= 0.95 * pairs and target
raise SystemExit(0 if ok else 1)
PY
}

budget() { /usr/bin/python3 -I -c "print($1 * $SCALE)"; }

# --- 1. guards -------------------------------------------------------------------
echo "-- 1. guards"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
if git rev-parse -q --verify 'master^{commit}' >/dev/null; then
    check "DCO sign-off (check-dco.sh master..HEAD)" scripts/ci/check-dco.sh master..HEAD
fi

# --- 2. build, tests and bundle ------------------------------------------------------
echo "-- 2. build, tests and bundle"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
    check "app unit tests (layout, model, view, window)" swift test --filter PrismAppTests
else
    check "release build zero warnings + swift test (build-strict.sh)" scripts/ci/build-strict.sh
fi
check "scripts/bundle.sh succeeds" scripts/bundle.sh
check "Info.plist declares document types (Finder and Dock drops)" \
    plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes xml1 -o - "$ACCEPT_APP/Contents/Info.plist"

# --- 3. small pair: changes, navigation, emphasis, themes ------------------------------
echo "-- 3. a.swift / b.swift"
check "launch a.swift b.swift" m03_launch -- "$TEXT/a.swift" "$TEXT/b.swift"
check "first paint recorded" wait_event firstPaint 15
check "8 changes, 21 + 21 lines" expect_perf firstPaint 'd["changes"] == 8 and d["linesA"] == 21 and d["linesB"] == 21'
check "first change selected: Change 1 of 8" label_is "Change 1 of 8"
if gui_available; then
    check "window 'Prism' shown" app_wait_window "Prism" 10
    check "capture light multicolor (compare with screen 02)" capture blocks-light-multicolor
    check "Cmd-Down x3" press_down 3
    check "perf log: Change 4 of 8" wait_until 5 label_is "Change 4 of 8"
    check "bottom bar (Accessibility): Change 4 of 8" ax_label_is "Change 4 of 8"
    check "capture after Cmd-Down x3" capture blocks-change-4
    check "selected change band emphasised (line-number cell colour)" \
        selected_band_emphasised "$ACCEPT_DIR/blocks-change-4.png"
fi
check "quit" app_quit

for theme in "dark-multicolor:-prism.text.dark YES -prism.text.singleColor NO:33" \
             "light-single:-prism.text.dark NO -prism.text.singleColor YES:35"; do
    IFS=: read -r name defaults screen <<<"$theme"
    # shellcheck disable=SC2086  # the defaults are separate words on purpose
    check "launch in $name" m03_launch -- $defaults "$TEXT/a.swift" "$TEXT/b.swift"
    check "$name: first paint, 8 changes" wait_event firstPaint 15
    if gui_available; then
        check "$name: Cmd-Down" press_down 1
        check "$name: Change 2 of 8" wait_until 5 label_is "Change 2 of 8"
        check "capture $name (compare with screen $screen)" capture "blocks-$name"
        check "$name: selected band uses the theme colour" \
            selected_band_emphasised "$ACCEPT_DIR/blocks-$name.png"
    fi
    check "quit" app_quit
done

# --- 4. big pair: first paint and memory ------------------------------------------------
echo "-- 4. big_a / big_b: first paint and memory"
check "launch big_a.txt big_b.txt" m03_launch -- "$TEXT/big_a.txt" "$TEXT/big_b.txt"
check "first paint recorded" wait_event firstPaint 20
check "944 changes" expect_perf firstPaint 'd["changes"] == 944'
check "first paint <= $(budget 500) ms after process start" \
    expect_perf firstPaint "d['sinceProcessStartMs'] <= $(budget 500)"
check "RSS <= 250 MB at first paint" expect_perf firstPaint 'd["rssMB"] <= 250'
check "main thread never blocked > 100 ms while loading" \
    expect_perf firstPaint "d['longestMainThreadGapMs'] <= $(budget 100)"
rss_now() {
    local kb
    kb=$(ps -o rss= -p "$ACCEPT_APP_PID" | tr -d ' ')
    echo "ps rss: $((kb / 1024)) MB"
    (( kb <= 250 * 1024 ))
}
check "RSS <= 250 MB (ps, settled)" rss_now
show_event firstPaint
check "quit" app_quit

# --- 5. responsiveness during a slow diff ---------------------------------------------------
echo "-- 5. UI responsive while the diff runs"
check "launch big pair with a 4 s artificial diff delay" \
    m03_launch PRISM_DEBUG_DIFF_DELAY_MS=4000 -- "$TEXT/big_a.txt" "$TEXT/big_b.txt"
check "loading placeholder appears (load > 150 ms)" wait_event placeholder 5
if gui_available; then
    check "window drag while loading succeeds" move_window_during_load
fi
check "comparison appears after the delay" wait_event firstPaint 20
check "main thread never blocked > 100 ms during the slow load" \
    expect_perf firstPaint "d['longestMainThreadGapMs'] <= $(budget 100)"
check "quit while idle" app_quit
check "launch again and quit mid-diff (cancellation)" \
    m03_launch PRISM_DEBUG_DIFF_DELAY_MS=4000 -- "$TEXT/big_a.txt" "$TEXT/big_b.txt"
check "quit during the load" app_quit

# --- 6. alignment after a jump -----------------------------------------------------------------
echo "-- 6. jump to change 473 of 944"
# 16 pt text keeps the OCR reliable on 1x displays as well.
check "launch big pair at change 473" \
    m03_launch -- -prism.text.fontSize 16 --change 473 "$TEXT/big_a.txt" "$TEXT/big_b.txt"
check "first paint recorded" wait_event firstPaint 20
check "Change 473 of 944 selected" wait_until 5 label_is "Change 473 of 944"
check "both panes at the same origin, no horizontal offset" \
    expect_perf selection 'd["scrollY"] == d["scrollYB"] and d["scrollY"] > 0 and d["scrollX"] == 0 and d["scrollXB"] == 0'
check "computed alignment error 0 pt" expect_perf selection 'd["alignmentErrorPt"] == 0'
if gui_available; then
    check "capture jump to 473" capture big-jump-473
    check "OCR: A and B show the same line at the same height" ocr_aligned "$ACCEPT_DIR/big-jump-473.png"
fi
check "quit" app_quit

# --- 7. scroll stress ------------------------------------------------------------------------------
echo "-- 7. scroll stress"
check "launch big pair with the scroll bench" m03_launch PRISM_BENCH_SCROLL=1 -- "$TEXT/big_a.txt" "$TEXT/big_b.txt"
check "scroll bench finished" wait_event scrollBench 120
show_event scrollBench
if [[ "${CI:-}" == true ]]; then
    # Shared CI runners have no real display timing; frame counts there
    # are recorded in the log but not judged.
    echo "notice: CI=true, missed-frame budgets not checked"
else
    check "smooth scroll (600 frames, 24 pt each) misses <= 2 frames" \
        expect_perf scrollBench 'd["smooth"]["missedFrames"] <= 2'
    check "full-document stress (0.9 screen per frame) misses <= 2 frames" \
        expect_perf scrollBench 'd["fullDocument"]["missedFrames"] <= 2'
fi
check "alignment stays exact while scrolling" expect_perf scrollBench 'd["alignmentErrorMaxPt"] == 0'
if [[ "$(perf_field scrollBench 'd["screenMaxFPS"]')" != 120 ]]; then
    echo "notice: the display runs at $(perf_field scrollBench 'd["screenMaxFPS"]') Hz, not 120 Hz"
fi
check "quit" app_quit

# --- 8. opening through Launch Services ------------------------------------------------------
echo "-- 8. open -a Prism a b"
open_with_launch_services() {
    : > "$PERF"
    app_pid >/dev/null && { echo "already running"; return 1; }
    open -n -a "$ACCEPT_APP" --env "PRISM_PERF_LOG=$PERF" "$TEXT/slider_a.groovy" "$TEXT/slider_b.groovy" || return 1
    wait_until 15 app_pid || return 1
    ACCEPT_APP_PID=$(app_pid)
}
check "open -n -a Prism.app slider_a slider_b" open_with_launch_services
check "comparison opened from the document event" wait_event firstPaint 15
check "slider pair: one change" expect_perf firstPaint 'd["changes"] == 1'
check "quit" app_quit
check "no Prism.app process left" bash -c '! pgrep -f "$0" >/dev/null' "$ACCEPT_EXEC"

accept_summary
