#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M1 (DiffCore engine, `prism diff` and
# `prism merge3`). Exit status: 0 when every check passes, 1 otherwise.
# It never launches Prism.app: every check is headless.
#
#   scripts/accept/M01.sh                 local run
#   CI=true PRISM_PERF_SCALE=3 scripts/accept/M01.sh
#                                         CI run (slower shared runners)
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (the release
#                               build of prism and PrismBench still runs)
#   PRISM_PERF_SCALE=<factor>   multiplies the perf budgets (default 1). The
#                               100x bound of the big case (130 ms) is
#                               absolute and never scaled.
#   PRISM_REFERENCE_FIXTURES=<dir>
#                               directory holding the original study pair
#                               a.swift and b.swift (default:
#                               $PRISM_DIRTY_ROOT/reference/fixtures when
#                               PRISM_DIRTY_ROOT is set). When present, the
#                               first acceptance bullet is also run on that
#                               exact pair; otherwise those checks are skipped.
#
# Mapping of the MILESTONES.md M1 acceptance bullets to sections below:
#   a.swift/b.swift JSON equals the golden, 8 changes  -> 3
#   slider insert at B lines 11-17                     -> 4
#   30k property cases, 0 failures                     -> 7
#   perf budgets                                       -> 8
#   cancel mid-diff returns within 50 ms               -> 9
#   merge3 matches the merge goldens                   -> 11
#   global definition of done                          -> 1 (and 12)
# Sections 5, 6 and 10 cover the CLI contract, the write-failure carry-over
# and the git --patience cross-check.
#
# Git runs with a throwaway HOME and global config, never ~/.gitconfig.
# Output of every check: build/accept/M01/checks.log.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

# No GUI in this milestone: do not even query System Events.
# shellcheck disable=SC2034  # read by gui_available in lib.sh
PRISM_ACCEPT_HEADLESS=1
accept_init M01

readonly CORPUS=Tests/corpus
readonly TEXT=$CORPUS/fixtures/text
readonly GOLDEN=$CORPUS/golden
SCALE="${PRISM_PERF_SCALE:-1}"
readonly SCALE

# Private scratch area and git environment, removed on exit.
SCRATCH="$(mktemp -d)"
readonly SCRATCH
mkdir -p "$SCRATCH/home" "$SCRATCH/out"
: > "$SCRATCH/gitconfig"
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1
m01_cleanup() {
    accept_cleanup
    rm -rf "$SCRATCH"
}
trap m01_cleanup EXIT
trap 'm01_cleanup; exit 130' INT TERM

# git with the throwaway HOME (HOME itself is exported only after the
# SwiftPM builds, which use the real caches).
git_q() {
    HOME="$SCRATCH/home" git "$@"
}

STATUS_BEFORE="$(git_q status --porcelain --untracked-files=all)"

# The version comes from the VERSION file (Plugins/VersionPlugin compiles it
# into PrismInfo.version).
VERSION="$(tr -d '[:space:]' < VERSION)"
echo "== VERSION: ${VERSION:-<not found>}, perf scale: $SCALE"

# --- check helpers -----------------------------------------------------------

exits_with() {      # exits_with <status> <command...>
    local want="$1" got=0; shift
    "$@" || got=$?
    echo "exit status $got (want $want)"
    (( got == want ))
}

# run_to <file> <want status> <command...>: stdout to the file, then the
# exit status must be the wanted one.
run_to() {
    local file="$1" want="$2" got=0; shift 2
    "$@" > "$file" || got=$?
    echo "exit status $got (want $want), $(wc -c < "$file" | tr -d ' ') bytes"
    (( got == want ))
}

same_bytes() {      # same_bytes <actual> <expected>
    cmp "$1" "$2" || { diff "$1" "$2" | head -n 20; return 1; }
}

file_has() {        # file_has <file> <fixed string>...
    local file="$1" s; shift
    [[ -f "$file" ]] || { echo "missing: $file"; return 1; }
    for s in "$@"; do
        grep -Fq -- "$s" "$file" || { echo "$file lacks: $s"; return 1; }
    done
}

file_lacks() {      # file_lacks <file> <fixed string>
    [[ -f "$1" ]] || { echo "missing: $1"; return 1; }
    ! grep -Fq -- "$2" "$1" || { echo "$1 contains: $2"; return 1; }
}

diffcore_foundation_free() {
    ! grep -rEn '^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(Foundation|AppKit|Cocoa)' Sources/DiffCore
}

no_original_identifiers() {
    ! grep -rEn --exclude-dir=generated '(^|[^A-Z])(KS|SF)[A-Z]' Sources Tests
}

changelog_ok() {
    # M1 shipped as its own milestone version (0.2.0); VERSION has moved on.
    grep -E "^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2} .*m01" CHANGELOG.md \
        || { echo "CHANGELOG.md has no '## [<version>] - <date> (... m01)' heading"; return 1; }
}

prints_version() {  # prints_version <binary>
    local out
    out=$("$1" --version) || return 1
    echo "output: $out"
    [[ -n "$VERSION" && "$out" == "$VERSION" ]]
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

ci_references() {
    file_has .github/workflows/ci.yml scripts/accept/M01.sh generate.py \
        PRISM_PERF_SCALE build/accept/M01
}

# manifest_complete <manifest> <dir>: every file under the directory is
# listed in the manifest (paths relative to Tests/corpus).
manifest_complete() {
    diff <(awk '{ print $2 }' "$CORPUS/$1" | sort) \
         <(cd "$CORPUS" && find "$2" -type f ! -name .DS_Store | sort)
}

fixtures_ok() {
    (cd "$CORPUS" && shasum -a 256 -c fixtures.sha256 --quiet) && manifest_complete fixtures.sha256 fixtures
}

merge_manifest_ok() {
    (cd "$CORPUS" && shasum -a 256 -c merge.sha256 --quiet) && manifest_complete merge.sha256 merge
}

generated_ok() {
    (cd "$CORPUS/generated" && shasum -a 256 -c ../generated.sha256 --quiet)
}

# json_field <file> <key>: integer value of a top-level key ("key":N or
# "key": N).
json_field() {
    /usr/bin/python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

field_is() {        # field_is <file> <key> <value>
    local got
    got=$(json_field "$1" "$2") || return 1
    echo "$2=$got (want $3)"
    [[ "$got" == "$3" ]]
}

slider_ok() {
    /usr/bin/python3 -I - "$1" <<'EOF'
import json, sys
blocks = [b for b in json.load(open(sys.argv[1]))["blocks"] if b["kind"] != "equal"]
print("non-equal blocks:", blocks)
ok = len(blocks) == 1 and blocks[0]["kind"] == "insert" and blocks[0]["b"] == [10, 17]
sys.exit(0 if ok else 1)
EOF
}

identical_ok() {
    local out="$SCRATCH/out/identical.txt"
    run_to "$out" 0 "$PRISM" diff "$TEXT/a.swift" "$TEXT/a.swift" || return 1
    [[ ! -s "$out" ]] || { echo "output is not empty"; return 1; }
    run_to "$out" 0 "$PRISM" diff --json "$TEXT/a.swift" "$TEXT/a.swift" || return 1
    field_is "$out" changes 0
}

ws1_crlf_ok() {
    local out="$SCRATCH/out/crlf-ws1.json"
    run_to "$out" 0 "$PRISM" diff --ws 1 --json "$CORPUS/generated/crlf_a.txt" "$CORPUS/generated/crlf_b.txt" || return 1
    field_is "$out" changes 0
}

unified_ok() {
    local out="$SCRATCH/out/unified.txt" headers
    run_to "$out" 1 "$PRISM" diff --unified "$TEXT/a.swift" "$TEXT/b.swift" || return 1
    headers=$(grep -c '^@@ -[0-9,]* +[0-9,]* @@' "$out")
    echo "@@ headers: $headers"
    (( headers >= 1 )) && file_has "$out" "--- $TEXT/a.swift" "+++ $TEXT/b.swift" \
        && same_bytes "$out" "$GOLDEN/diff-a-b.unified.txt"
}

side_by_side_ok() {
    local out="$SCRATCH/out/side-by-side.txt"
    run_to "$out" 1 env -u COLUMNS "$PRISM" diff --side-by-side --width 160 "$TEXT/a.swift" "$TEXT/b.swift" \
        && same_bytes "$out" "$GOLDEN/diff-a-b.side-by-side.txt"
}

color_ok() {
    local esc=$'\033[' mode out
    for mode in --unified --side-by-side; do
        out="$SCRATCH/out/color$mode.txt"
        run_to "$out" 1 "$PRISM" diff "$mode" --color "$TEXT/a.swift" "$TEXT/b.swift" || return 1
        file_has "$out" "$esc" || return 1
        out="$SCRATCH/out/plain$mode.txt"
        run_to "$out" 1 "$PRISM" diff "$mode" "$TEXT/a.swift" "$TEXT/b.swift" || return 1
        file_lacks "$out" "$esc" || return 1
    done
}

# Carry-over 1: output that cannot be written is a failure of its own
# (status 2), neither "differ" (1) nor a signal (>= 128).
closed_stdout_ok() {
    local s=0
    "$PRISM" diff "$TEXT/a.swift" "$TEXT/b.swift" >&- 2>/dev/null || s=$?
    echo "exit status $s (want != 0, != 1, < 128)"
    (( s != 0 && s != 1 && s < 128 ))
}

# pipe_inputs_ok: process substitution, a named FIFO and '-' (standard
# input) are read like files.
pipe_inputs_ok() {
    local out="$SCRATCH/out/pipes.txt" dir s=0
    "$PRISM" diff --ws 2 <(printf 'a\n') <(printf 'b\n') > "$out" 2>&1 || s=$?
    echo "process substitution: exit $s"; cat "$out"
    (( s == 1 )) && file_has "$out" "-a" "+b" || return 1
    s=0
    printf 'x\n' | "$PRISM" diff - /dev/null > "$out" 2>&1 || s=$?
    echo "standard input: exit $s"; cat "$out"
    (( s == 1 )) && file_has "$out" "-x" || return 1
    dir="$(mktemp -d)" || return 1
    mkfifo "$dir/fifo"
    printf 'y\n' > "$dir/fifo" &
    s=0
    "$PRISM" diff "$dir/fifo" /dev/null > "$out" 2>&1 || s=$?
    wait
    rm -rf "$dir"
    echo "named FIFO: exit $s"; cat "$out"
    (( s == 1 )) && file_has "$out" "-y"
}

# unified_patch_ok: a change followed by a deletion, with no final newline
# on B, applies with patch(1) (removed lines come before added lines).
unified_patch_ok() {
    local dir rc=0
    dir="$(mktemp -d)" || return 1
    printf 'one\ntwo\nthree\n' > "$dir/a"
    printf 'one 1\ntwo' > "$dir/b"
    "$PRISM" diff "$dir/a" "$dir/b" > "$dir/p.diff"
    cat "$dir/p.diff"
    /usr/bin/patch -s -i "$dir/p.diff" "$dir/a" && cmp "$dir/a" "$dir/b" || rc=1
    rm -rf "$dir"
    return "$rc"
}

# broken_pipe_ok: a pipe broken before the tool starts (FIFO trick of
# M00.sh, no race). With SIGPIPE at its default the tool ends by SIGPIPE,
# as diff(1) does (status 141); with SIGPIPE ignored it exits 2.
broken_pipe_ok() {
    local dir s rc=0 disposition
    dir="$(mktemp -d)" || return 1
    mkfifo "$dir/fifo"
    # perl sets the disposition explicitly: a shell cannot reset a SIGPIPE
    # that was already ignored when it started.
    for disposition in DEFAULT IGNORE; do
        s=0
        (
            # shellcheck disable=SC2094  # both ends of the FIFO, on purpose
            exec 3<>"$dir/fifo" 4>"$dir/fifo" 3<&-
            exec /usr/bin/perl -e '$SIG{PIPE} = shift; exec @ARGV or exit 127' "$disposition" \
                "$PRISM" diff "$TEXT/a.swift" "$TEXT/b.swift" >&4 2>/dev/null
        ) || s=$?
        echo "SIGPIPE $disposition: exit $s"
        if [[ "$disposition" == DEFAULT ]]; then (( s == 141 )) || rc=1; else (( s == 2 )) || rc=1; fi
    done
    rm -rf "$dir"
    return "$rc"
}

property_ok() {
    local out="$SCRATCH/out/property.txt" rc=0
    "$BENCH" property 5000 > "$out" 2>&1 || rc=$?
    cat "$out"
    (( rc == 0 )) && grep -Eq '(^| )cases=30000 failures=0( |$)' "$out"
}

# kv <line> <key>: value of key=value in a bench line.
kv() {
    tr ' ' '\n' <<<"$1" | sed -n "s/^$2=//p" | head -n 1
}

# perf_case <case> <budget ms> [absolute cap ms]: the median from the perf
# run is within budget x SCALE (and the cap), and the bench agrees.
perf_case() {
    local name="$1" budget="$2" cap="${3:-}" line median
    line=$(grep -E "^case=$name ws=0 " "$ACCEPT_DIR/perf.txt" | head -n 1)
    [[ -n "$line" ]] || { echo "no perf line for $name"; return 1; }
    echo "$line"
    median=$(kv "$line" median_ms)
    awk -v m="$median" -v b="$budget" -v s="$SCALE" -v c="$cap" 'BEGIN {
        limit = b * s
        if (c != "" && limit > c) limit = c
        printf "median %s ms, limit %.3f ms\n", m, limit
        exit !(m != "" && m + 0 <= limit)
    }' || return 1
    [[ "$(kv "$line" result)" == pass ]]
}

cancel_ok() {
    local out="$ACCEPT_DIR/cancel.txt" line n=0 bad=0 latency
    [[ -s "$out" ]] || { echo "no cancel output"; return 1; }
    while IFS= read -r line; do
        n=$((n + 1))
        latency=$(kv "$line" latency_ms)
        echo "$line"
        awk -v l="$latency" 'BEGIN { exit !(l != "" && l + 0 <= 50) }' || { echo "  over 50 ms"; bad=1; }
        [[ "$(kv "$line" result)" == pass ]] || bad=1
    done < <(grep -E '^case=' "$out")
    echo "cases: $n"
    (( n >= 4 && bad == 0 )) && grep -q 'failures=0' "$out" \
        && grep -q '^case=disjoint300k ' "$out" && grep -q '^case=disjoint1000k ' "$out"
}

gitcheck_case() {   # gitcheck_case <case>
    local line prism git
    line=$(grep -E "^case=$1 " "$ACCEPT_DIR/gitcheck.txt" | head -n 1)
    [[ -n "$line" ]] || { echo "no gitcheck line for $1"; return 1; }
    echo "$line"
    prism=$(kv "$line" prism); git=$(kv "$line" git)
    [[ -n "$prism" && "$prism" == "$git" && "$(kv "$line" result)" == pass ]]
}

# merge_case <dir>: merge3 output equals expected.json; the exit status is
# 1 when the expected result has conflicts, 0 otherwise.
merge_case() {
    local dir="$1" out want conflicts args=()
    out="$SCRATCH/out/merge-$(basename "$dir").json"
    if [[ -f "$dir/args.txt" ]]; then
        read -r -a args < "$dir/args.txt"
    fi
    conflicts=$(json_field "$dir/expected.json" conflicts) || return 1
    want=0; (( conflicts > 0 )) && want=1
    echo "expected conflicts: $conflicts"
    run_to "$out" "$want" "$PRISM" merge3 ${args[@]+"${args[@]}"} "$dir/base.txt" "$dir/a.txt" "$dir/b.txt" --json \
        && same_bytes "$out" "$dir/expected.json"
}

merge_cases_present() {
    local n
    n=$(find "$CORPUS/merge" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    echo "merge cases: $n"
    (( n >= 8 )) && field_is "$CORPUS/merge/notes/expected.json" conflicts 1
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
# One product per invocation: given several --product flags, SwiftPM builds
# only the last one.
release_products() {
    swift build -c release --product prism && swift build -c release --product PrismBench
}
check "release build of prism and PrismBench" release_products
BIN="$(swift build -c release --show-bin-path 2>/dev/null)"
PRISM="$BIN/prism"
BENCH="$BIN/PrismBench"
export PRISM_BIN="$BIN"
echo "== binaries: $BIN"

# From here on nothing needs the real home directory.
export HOME="$SCRATCH/home"

if ! generated_ok >/dev/null 2>&1; then
    check "generate the large corpus inputs (generate.py)" \
        /usr/bin/python3 -I "$CORPUS/scripts/generate.py"
fi

# --- 1. global definition of done ---------------------------------------------
echo "-- 1. definition of done"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
check "DiffCore imports no Foundation" diffcore_foundation_free
check "no KS*/SF* identifiers in Sources or Tests" no_original_identifiers
check "DCO sign-off (check-dco.sh)" dco_check
check "CHANGELOG.md has a dated release heading for m01" changelog_ok
check "prism --version prints $VERSION" prints_version "$PRISM"
check "ci.yml generates the corpus and runs M01.sh" ci_references

# --- 2. corpus integrity -------------------------------------------------------
echo "-- 2. corpus"
check "fixtures match fixtures.sha256 (and are all listed)" fixtures_ok
check "merge cases match merge.sha256 (and are all listed)" merge_manifest_ok
check "generated inputs match generated.sha256" generated_ok

# --- 3. golden diff --------------------------------------------------------------
echo "-- 3. golden diff"
readonly AB_JSON="$SCRATCH/out/diff-a-b.json"
check "prism diff a.swift b.swift --json exits 1" \
    run_to "$AB_JSON" 1 "$PRISM" diff "$TEXT/a.swift" "$TEXT/b.swift" --json
check "JSON equals golden/diff-a-b.json" same_bytes "$AB_JSON" "$GOLDEN/diff-a-b.json"
check "JSON reports 8 changes" field_is "$AB_JSON" changes 8
check "word range: \" a friendly \" at B columns [13,24]" file_has "$AB_JSON" \
    '{"aLine":2,"bLine":3,"a":[13,13],"b":[13,24],"aUTF16":[13,13],"bUTF16":[13,24]}'

# The repository's b.swift names Prism where the original study pair names
# another product (Tests/corpus/README.md), so the bullet as worded is also
# run on the original pair when it is available. That pair stays outside the
# repository; only its ranges-only JSON golden is committed.
REFERENCE_FIXTURES="${PRISM_REFERENCE_FIXTURES:-${PRISM_DIRTY_ROOT:+$PRISM_DIRTY_ROOT/reference/fixtures}}"
if [[ -n "$REFERENCE_FIXTURES" && -f "$REFERENCE_FIXTURES/a.swift" && -f "$REFERENCE_FIXTURES/b.swift" ]]; then
    readonly REF_JSON="$SCRATCH/out/diff-reference-a-b.json"
    check "original pair: a.swift is byte-identical to the repository copy" \
        cmp "$REFERENCE_FIXTURES/a.swift" "$TEXT/a.swift"
    check "original pair: prism diff --json exits 1" \
        run_to "$REF_JSON" 1 "$PRISM" diff "$REFERENCE_FIXTURES/a.swift" "$REFERENCE_FIXTURES/b.swift" --json
    check "original pair: JSON equals golden/diff-reference-a-b.json, 8 changes" \
        same_bytes "$REF_JSON" "$GOLDEN/diff-reference-a-b.json"
else
    echo "SKIP  original study pair not available (set PRISM_REFERENCE_FIXTURES or PRISM_DIRTY_ROOT)"
fi

# --- 4. slider -----------------------------------------------------------------
echo "-- 4. slider"
readonly SLIDER_JSON="$SCRATCH/out/slider.json"
check "prism diff slider --json exits 1" \
    run_to "$SLIDER_JSON" 1 "$PRISM" diff "$TEXT/slider_a.groovy" "$TEXT/slider_b.groovy" --json
check "one insert at b [10,17] (B lines 11-17)" slider_ok "$SLIDER_JSON"
check "slider JSON equals golden/diff-slider.json" same_bytes "$SLIDER_JSON" "$GOLDEN/diff-slider.json"

# --- 5. CLI behaviour ------------------------------------------------------------
echo "-- 5. CLI behaviour"
check "identical files exit 0 with no output, 0 changes" identical_ok
check "missing file exits 2" exits_with 2 "$PRISM" diff "$TEXT/a.swift" "$SCRATCH/does-not-exist"
check "--ws 1 on CRLF vs LF exits 0 with 0 changes" ws1_crlf_ok
check "--unified has @@ headers and equals its golden" unified_ok
check "--side-by-side equals its golden" side_by_side_ok
check "--color writes ESC[, the default output does not" color_ok
check "process substitution, a FIFO and '-' are read as inputs" pipe_inputs_ok
check "unified output applies with patch(1)" unified_patch_ok

# --- 6. write failure (carry-over 1) ------------------------------------------------
echo "-- 6. write failure"
check "closed stdout: non-zero, not 1, no signal" closed_stdout_ok
check "broken pipe: SIGPIPE by default (141), exit 2 when ignored" broken_pipe_ok

# --- 7. property ----------------------------------------------------------------------
echo "-- 7. property"
check "PrismBench property 5000: cases=30000 failures=0" property_ok

# --- 8. perf ----------------------------------------------------------------------------
echo "-- 8. perf (scale $SCALE)"
"$BENCH" perf --scale "$SCALE" > "$ACCEPT_DIR/perf.txt" 2>&1
echo "perf exit status $?" >> "$ACCEPT_DIR/perf.txt"
check "perf big <= 40 ms x $SCALE, and <= 130 ms" perf_case big 40 130
check "perf m1 (1M lines, 10 edits) <= 400 ms x $SCALE" perf_case m1 400
check "perf crlf ws=0 <= 300 ms x $SCALE" perf_case crlf 300
check "perf diff20k <= 2000 ms x $SCALE" perf_case diff20k 2000

# --- 9. cancellation ---------------------------------------------------------------------
echo "-- 9. cancellation"
"$BENCH" cancel > "$ACCEPT_DIR/cancel.txt" 2>&1
check "PrismBench cancel: every latency <= 50 ms (incl. disjoint 300k/1M, production options)" cancel_ok

# --- 10. git cross-check ---------------------------------------------------------------------
echo "-- 10. git --patience cross-check"
"$BENCH" gitcheck > "$ACCEPT_DIR/gitcheck.txt" 2>&1
for name in ab big slider m1 diff20k; do
    check "hunk count equals git --patience: $name" gitcheck_case "$name"
done

# --- 11. merge3 --------------------------------------------------------------------------------
echo "-- 11. merge3"
check "at least 8 merge cases; notes has 1 conflict" merge_cases_present
for dir in "$CORPUS"/merge/*/; do
    dir="${dir%/}"
    check "merge3 $(basename "$dir") equals expected.json, exit status by conflicts" merge_case "$dir"
done

# --- 12. hygiene ----------------------------------------------------------------------------------
echo "-- 12. hygiene"
check "git status unchanged by the run" worktree_unchanged

accept_summary
