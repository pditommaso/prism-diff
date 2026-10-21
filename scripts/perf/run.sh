#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Headless performance regression suite (M11). Every budget is one test,
# printed as a PASS or FAIL line; the script exits 0 only when all pass.
# Nothing here shows a window: the first-screen cases run the app binary
# in its headless bench mode (no window, no Dock icon, no run loop).
#
#   engine        PrismBench perf: median engine time per corpus case
#                 (M1: big <= 40 ms and never over 130 ms, m1 <= 400 ms,
#                 crlf ws=0 <= 300 ms, diff20k <= 2000 ms)
#   ipc           PrismIPCStub bench: warm round trip of the prism CLI's app-integration
#                 requests, median
#                 <= 1 ms over 500 requests (M5)
#   folder        PrismBench folderperf on the generated 200k-file tree:
#                 first rows <= 50 ms, deep pass <= 2 s warm, RSS <= 150 MB
#                 (M8); folderwatch: a touched file's row updates <= 200 ms
#   first screen  Prism --bench-first-screen: read, diff and model build,
#                 layout and an offscreen draw of the first screen (M3/M4:
#                 100k-line pair <= 500 ms in Blocks, Unified and wrapped,
#                 RSS <= 250 MB; a 5 MB single line <= 3000 ms)
#
# Usage: scripts/perf/run.sh
# Environment:
#   PRISM_PERF_SCALE=<factor>   multiplies every time budget (default 1; CI
#                               uses 3 on shared runners). The 130 ms bound
#                               of the big engine case is absolute.
#   PRISM_PERF_FOLDER_SCAN_SCALE=<factor>
#                               multiplies the folder deep-pass budget instead
#                               (default PRISM_PERF_SCALE; CI uses 8, see
#                               ci.yml)
#   PRISM_PERF_SKIP_BUILD=1     use the existing release build
#   PRISM_FOLDER_GEN=<dir>      where the 200k-file tree lives or is generated
#                               (default build/folder-gen, shared with M08.sh)
# Output: build/perf/ (one log per group and results.txt).
set -uo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT" || exit 1

SCALE="${PRISM_PERF_SCALE:-1}"
SCAN_SCALE="${PRISM_PERF_FOLDER_SCAN_SCALE:-$SCALE}"
GEN="${PRISM_FOLDER_GEN:-$ROOT/build/folder-gen}"
OUT="$ROOT/build/perf"
readonly SCALE SCAN_SCALE GEN OUT
mkdir -p "$OUT"
: > "$OUT/results.txt"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/prism-perf.XXXXXX")
STUB_PID=""
cleanup() {
    if [[ -n "$STUB_PID" ]]; then
        kill -TERM "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
    fi
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

passed=0 failed=0
result() {   # result <pass|fail> <description>
    local word=PASS
    if [[ "$1" == pass ]]; then passed=$((passed + 1)); else word=FAIL; failed=$((failed + 1)); fi
    echo "$word $2" | tee -a "$OUT/results.txt"
}
budget() { /usr/bin/python3 -I -c "import sys; print(round(float(sys.argv[1]) * float(sys.argv[2]), 3))" "$1" "${2:-$SCALE}"; }

# bench_lines <log>: one test per PASS/FAIL line of a PrismBench report.
bench_lines() {
    local line found=0
    while IFS= read -r line; do
        case "$line" in
            "PASS "*) result pass "${line#PASS }"; found=1 ;;
            "FAIL "*) result fail "${line#FAIL }"; found=1 ;;
        esac
    done < "$1"
    (( found )) || result fail "no checks reported in $(basename "$1")"
}

echo "== perf suite (scale $SCALE)"

# --- build ------------------------------------------------------------------
if [[ "${PRISM_PERF_SKIP_BUILD:-}" != 1 ]]; then
    for product in PrismBench PrismIPCStub PrismApp; do
        if ! swift build -c release --product "$product" > "$OUT/build-$product.log" 2>&1; then
            tail -n 20 "$OUT/build-$product.log"
            result fail "release build of $product"
            exit 1
        fi
    done
fi
BIN=$(swift build -c release --show-bin-path)
for product in PrismBench PrismIPCStub PrismApp; do
    [[ -x "$BIN/$product" ]] || { result fail "missing $BIN/$product"; exit 1; }
done

# --- corpus -----------------------------------------------------------------
if ! (cd Tests/corpus/generated 2>/dev/null && shasum -a 256 -c ../generated.sha256 --quiet >/dev/null 2>&1); then
    echo "-- generating the large corpus inputs"
    /usr/bin/python3 -I Tests/corpus/scripts/generate.py > "$OUT/generate.log" 2>&1
    if ! (cd Tests/corpus/generated && shasum -a 256 -c ../generated.sha256 --quiet); then
        result fail "generated corpus matches Tests/corpus/generated.sha256"
        exit 1
    fi
fi
TEXT=Tests/corpus/fixtures/text
GENERATED=Tests/corpus/generated

# --- engine (M1) ---------------------------------------------------------------
echo "-- engine"
"$BIN/PrismBench" perf --scale "$SCALE" > "$OUT/engine.log" 2>&1
bench_lines "$OUT/engine.log"

# --- IPC round trip (M5) -----------------------------------------------------------
echo "-- ipc"
socket="$SCRATCH/s.sock"
"$BIN/PrismIPCStub" serve --socket "$socket" 2> "$OUT/ipc-stub.log" &
STUB_PID=$!
for _ in $(seq 100); do
    "$BIN/PrismIPCStub" status --socket "$socket" > /dev/null 2>&1 && break
    sleep 0.1
done
if json=$("$BIN/PrismIPCStub" bench --socket "$socket" --count 500 2> "$OUT/ipc.log"); then
    echo "$json" >> "$OUT/ipc.log"
    limit=$(budget 1)
    verdict=$(/usr/bin/python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
ok = d["median_ms"] <= float(sys.argv[2])
print(("pass" if ok else "fail") + " warm round trip median %.3f ms, p95 %.3f ms, limit %s ms (500 requests)"
      % (d["median_ms"], d.get("p95_ms", float("nan")), sys.argv[2]))' "$json" "$limit")
    result "${verdict%% *}" "ipc: ${verdict#* }"
else
    result fail "ipc: the round-trip bench ran (see $OUT/ipc.log)"
fi
kill -TERM "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""

# --- folder scan (M8) ----------------------------------------------------------------
echo "-- folder"
if "$BIN/PrismBench" foldergen "$GEN" > "$OUT/foldergen.log" 2>&1; then
    "$BIN/PrismBench" folderperf --first-rows-ms "$(budget 50)" --deep-ms "$(budget 2000 "$SCAN_SCALE")" --expect 14,6,1 "$GEN/left" "$GEN/right" > "$OUT/folder.log" 2>&1
    bench_lines "$OUT/folder.log"
    deep=$(cd "$GEN/right" && find top03 -type f -name 'file*' | sort | head -n 1)
    "$BIN/PrismBench" folderwatch --budget-ms "$(budget 200)" --touch "$deep" "$GEN/left" "$GEN/right" \
        > "$OUT/folderwatch.log" 2>&1
    bench_lines "$OUT/folderwatch.log"
else
    result fail "folder: generate the 200k-file tree (see $OUT/foldergen.log)"
fi

# --- first screen (M3/M4) -------------------------------------------------------------
echo "-- first screen"
# first_screen <name> <budget ms> <python condition on d> <bench args...>
first_screen() {
    local name="$1" limit; limit=$(budget "$2"); local extra="$3"; shift 3
    local json
    if ! json=$("$BIN/PrismApp" --bench-first-screen "$@" 2>> "$OUT/first-screen.log"); then
        result fail "first screen $name: the bench ran (see $OUT/first-screen.log)"
        return
    fi
    echo "$name $json" >> "$OUT/first-screen.log"
    local verdict
    verdict=$(/usr/bin/python3 -I -c '
import json, sys
d = json.loads(sys.argv[1]); limit = float(sys.argv[2])
ok = d["totalMs"] <= limit and d["painted"] and eval(sys.argv[3], {}, {"d": d})
print(("pass" if ok else "fail")
      + " total %.1f ms (read %.1f, build %.1f, layout %.1f, draw %.1f), limit %s ms, %d changes, RSS %.0f MB, both panes drawn: %s; %s"
      % (d["totalMs"], d["readMs"], d["buildMs"], d["layoutMs"], d["drawMs"], sys.argv[2], d["changes"], d["rssMB"],
         d["painted"], sys.argv[3]))' "$json" "$limit" "$extra")
    result "${verdict%% *}" "first screen $name: ${verdict#* }"
}
big=("$TEXT/big_a.txt" "$TEXT/big_b.txt")
first_screen "big, Blocks" 500 'd["changes"] == 944 and d["rssMB"] <= 250' --mode blocks "${big[@]}"
first_screen "big, Unified" 500 'd["changes"] == 944 and d["rssMB"] <= 250' --mode unified "${big[@]}"
first_screen "big, Blocks wrapped at 600 pt" 500 'd["changes"] == 944 and d["rssMB"] <= 250' \
    --mode blocks --wrap --width 600 "${big[@]}"
first_screen "5 MB single line, Blocks" 3000 'd["linesA"] == 1' --mode blocks "$GENERATED/min_a.json" "$GENERATED/min_b.json"

echo "== perf suite: $passed passed, $failed failed (scale $SCALE); log in ${OUT#"$ROOT/"}/"
(( failed == 0 ))
