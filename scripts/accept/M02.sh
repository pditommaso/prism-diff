#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M2 (text import: encodings, binary
# detection, document conversion, `prism sniff`), plus the M1 carry-overs
# assigned to M2. Exit status: 0 when every check passes, 1 otherwise. It
# never launches Prism.app: every check is headless.
#
#   scripts/accept/M02.sh                       local run
#   CI=true PRISM_PERF_SCALE=3 scripts/accept/M02.sh
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (the release
#                               build of prism and the TextImport tests
#                               still run)
#   PRISM_PERF_SCALE=<factor>   multiplies the time budgets (default 1)
#
# Mapping of the MILESTONES.md M2 acceptance bullets to sections below:
#   corpus classified correctly, decode/encode byte-identical -> 2, 3
#   PNG, Mach-O, zip report binary, prism diff exits 2         -> 4
#   RTF and PDF fixtures give the expected text               -> 5
#   100 MB text import <= 1 s                                 -> 6
#   global definition of done                                 -> 1 (and 9)
# Section 7 covers the `prism sniff` contract, section 8 the carry-overs
# (CJK words, character scoring, final newline at ws 1/2, side-by-side
# truncation, merge3 base guard).
#
# Output of every check: build/accept/M02/checks.log.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

# No GUI in this milestone: do not even query System Events.
# shellcheck disable=SC2034  # read by gui_available in lib.sh
PRISM_ACCEPT_HEADLESS=1
accept_init M02

readonly CORPUS=Tests/corpus
readonly ENC=$CORPUS/encodings
SCALE="${PRISM_PERF_SCALE:-1}"
readonly SCALE

SCRATCH="$(mktemp -d)"
readonly SCRATCH
mkdir -p "$SCRATCH/home" "$SCRATCH/out"
: > "$SCRATCH/gitconfig"
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig" GIT_CONFIG_NOSYSTEM=1
m02_cleanup() {
    accept_cleanup
    rm -rf "$SCRATCH"
}
trap m02_cleanup EXIT
trap 'm02_cleanup; exit 130' INT TERM

git_q() {
    HOME="$SCRATCH/home" git "$@"
}

STATUS_BEFORE="$(git_q status --porcelain --untracked-files=all)"

# --- check helpers -----------------------------------------------------------

exits_with() {      # exits_with <status> <command...>
    local want="$1" got=0; shift
    "$@" || got=$?
    echo "exit status $got (want $want)"
    (( got == want ))
}

file_has() {        # file_has <file> <fixed string>...
    local file="$1" s; shift
    [[ -f "$file" ]] || { echo "missing: $file"; return 1; }
    for s in "$@"; do
        grep -Fq -- "$s" "$file" || { echo "$file lacks: $s"; cat "$file"; return 1; }
    done
}

# elapsed_ms <command...>: runs the command (output discarded) and prints
# its wall time in milliseconds; fails when the command exits with a status
# above 1 (1 is "differences found") or is killed.
elapsed_ms() {
    perl -MTime::HiRes=time -e '
        open(STDOUT, ">", "/dev/null");
        my $t = time; my $rc = system(@ARGV); my $ms = int((time - $t) * 1000);
        print STDERR "$ms\n"; exit(($rc & 127) == 0 && ($rc >> 8) <= 1 ? 0 : 1);' "$@" 2> "$SCRATCH/elapsed"
    local rc=$?
    cat "$SCRATCH/elapsed"
    return $rc
}

# within_budget <name> <budget ms> <command...>: best of three runs must be
# within the budget times PRISM_PERF_SCALE.
within_budget() {
    local name="$1" budget="$2" best="" ms i limit; shift 2
    limit=$(perl -e "print int($budget * $SCALE)")
    for i in 1 2 3; do
        ms=$(elapsed_ms "$@") || { echo "$name: command failed"; return 1; }
        echo "$name run $i: $ms ms"
        [[ -z "$best" || "$ms" -lt "$best" ]] && best=$ms
    done
    echo "$name best: $best ms (budget $limit ms)" | tee -a "$ACCEPT_DIR/perf.txt"
    (( best <= limit ))
}

diffcore_foundation_free() {
    ! grep -rEn '^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(Foundation|AppKit|Cocoa)' Sources/DiffCore
}

no_original_identifiers() {
    ! grep -rEn --exclude-dir=generated '(^|[^A-Z])(KS|SF)[A-Z]' Sources Tests
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
    # The m02 entry sits under [Unreleased] until the version is bumped at
    # merge time, or under its own version heading afterwards.
    grep -Eiq '^#+ .*m02' CHANGELOG.md && grep -Fq 'prism sniff' CHANGELOG.md \
        || { echo "CHANGELOG.md has no m02 entry mentioning prism sniff"; return 1; }
}

docs_ok() {
    file_has docs/spec-public/prism-cli.md '## `prism sniff`' 'prism sniff  [--json] FILE ...' \
        'binary file; only text files can be compared'
}

ci_references() {
    file_has .github/workflows/ci.yml scripts/accept/M02.sh build/accept/M02
}

manifest_ok() {
    (cd "$CORPUS" && shasum -a 256 -c encodings.sha256 --quiet) || return 1
    diff <(awk '{ print $2 }' "$CORPUS/encodings.sha256" | sort) \
         <(cd "$CORPUS" && find encodings -type f ! -name .DS_Store | sort)
}

# sniff_json <file>: `prism sniff --json` of one file into $SCRATCH/out.
sniff_json() {
    local out="$SCRATCH/out/sniff-$(basename "$1").json"
    "$PRISM" sniff --json "$1" > "$out" || return 1
    echo "$out"
}

# classified_as <file> <kind> <encoding-or-format> <bom> <line-endings>:
# the sniff report matches a row of expected.tsv; text files must also
# report round-trip: true.
classified_as() {
    local out
    out=$(sniff_json "$1") || { echo "sniff failed"; return 1; }
    cat "$out"
    /usr/bin/python3 -I - "$out" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
kind, enc, bom, endings = sys.argv[2:6]
ok = r["kind"] == kind
if kind == "text":
    ok = ok and r["encoding"] == enc and r["bom"] == (bom == "yes") \
        and r["line-endings"] == endings and r["round-trip"] is True
elif kind == "document":
    ok = ok and r["format"] == enc and r["line-endings"] == endings
else:
    ok = ok and "encoding" not in r
sys.exit(0 if ok else 1)
PY
}

# round_trip_ok: decode then encode is byte-identical for every text file
# of the corpus (the TextImport test that compares the bytes).
round_trip_ok() {
    swift test --filter 'decodeThenEncodeIsByteIdentical|utf32WithBOMRoundTrips|windows1252WithoutHighControlsIsLatin1' 2>&1 \
        | tee "$SCRATCH/out/roundtrip.log" | grep -E '✘|✔ Test run|error:' 
    grep -q '✔ Test run with' "$SCRATCH/out/roundtrip.log" && ! grep -q '✘' "$SCRATCH/out/roundtrip.log"
}

# Decoded text is the same whatever the encoding: diff exits 0.
same_text() {       # same_text <a> <b>
    exits_with 0 "$PRISM" diff "$1" "$2"
}

# refused <file>: prism diff against a text file exits 2 and says why.
refused() {
    local err="$SCRATCH/out/refused.err" s=0
    "$PRISM" diff "$ENC/utf8.txt" "$1" > "$SCRATCH/out/refused.out" 2> "$err" || s=$?
    echo "exit $s"; cat "$err"
    (( s == 2 )) && [[ ! -s "$SCRATCH/out/refused.out" ]] \
        && file_has "$err" "$1: binary file; only text files can be compared"
}

reports_binary() {  # reports_binary <file>
    local out
    out=$(sniff_json "$1") || return 1
    cat "$out"
    file_has "$out" '"kind":"binary"'
}

document_text() {   # document_text <format>
    exits_with 0 "$PRISM" diff "$ENC/doc.$1.expected" "$ENC/doc.$1"
}

# make_big: about 100 MB of UTF-8 text (the 100k-line fixture, repeated),
# plus the same text in ISO-8859-1 and UTF-16, in the scratch directory.
make_big() {
    local i
    for i in $(seq 1 19); do cat "$CORPUS/fixtures/text/big_a.txt"; done > "$SCRATCH/big-utf8.txt"
    LC_ALL=C tr 'e' '\351' < "$SCRATCH/big-utf8.txt" > "$SCRATCH/big-latin1.txt"
    iconv -f UTF-8 -t UTF-16LE "$SCRATCH/big-utf8.txt" > "$SCRATCH/big-utf16.txt"
    ls -l "$SCRATCH"/big-*.txt
    (( $(wc -c < "$SCRATCH/big-utf8.txt") >= 100000000 ))
}

big_classified() {  # big_classified <file> <encoding>
    local out
    out=$(sniff_json "$1") || return 1
    cat "$out"
    file_has "$out" "\"encoding\":\"$2\"" '"lines":1900000'
}

sniff_text_ok() {
    local out="$SCRATCH/out/sniff.txt"
    "$PRISM" sniff "$ENC/shift-jis.txt" "$SCRATCH/missing" > "$out" || return 1
    cat "$out"
    file_has "$out" "file: $ENC/shift-jis.txt" "kind: text" "encoding: shift_jis" "bom: no" \
        "line-endings: crlf" "lines: 3" "final-newline: yes" "round-trip: yes" \
        "file: $SCRATCH/missing" "kind: missing" || return 1
    grep -c '^$' "$out" | grep -qx 1 || { echo "want exactly one blank line between the two records"; return 1; }
}

sniff_stdin_ok() {
    local out="$SCRATCH/out/sniff-stdin.txt"
    "$PRISM" sniff - < "$ENC/utf16be-bom.txt" > "$out" || return 1
    file_has "$out" "file: -" "encoding: utf-16be" "bom: yes"
}

sniff_folder_ok() {
    local out="$SCRATCH/out/sniff-folder.txt"
    "$PRISM" sniff "$ENC" > "$out" || return 1
    file_has "$out" "kind: directory"
}

sniff_unreadable_ok() {
    local locked="$SCRATCH/locked.txt" out="$SCRATCH/out/sniff-locked.txt" s=0
    printf 'x\n' > "$locked"
    chmod 000 "$locked"
    if [[ -r "$locked" ]]; then echo "notice: running as root, cannot make a file unreadable"; return 0; fi
    "$PRISM" sniff "$locked" /dev/null > "$out" 2> "$out.err" || s=$?
    chmod 644 "$locked"
    echo "exit $s"; cat "$out.err"
    (( s == 2 )) && file_has "$out.err" "$locked: Permission denied" && file_has "$out" "file: /dev/null"
}

help_lists_sniff() {
    local out="$SCRATCH/out/help.txt"
    "$PRISM" --help > "$out" || return 1
    file_has "$out" "  sniff " && ! grep -q "Not yet available" "$out"
}

# --- carry-overs ---------------------------------------------------------------

cjk_words_ok() {
    local out="$SCRATCH/out/cjk.json" s=0
    printf '今日は良い天気です。\n' > "$SCRATCH/cjk_a.txt"
    printf '今日は悪い天気です。\n' > "$SCRATCH/cjk_b.txt"
    "$PRISM" diff --json "$SCRATCH/cjk_a.txt" "$SCRATCH/cjk_b.txt" > "$out" || s=$?
    cat "$out"
    (( s == 1 )) && file_has "$out" '"words":[{"aLine":0,"bLine":0,"a":[9,12],"b":[9,12],"aUTF16":[3,4],"bUTF16":[3,4]}]'
}

char_scoring_ok() {
    local out="$SCRATCH/out/scoring.json" s=0
    printf 'ééééé-abcdefgh\n' > "$SCRATCH/score_a.txt"
    printf 'ééééé+x\ny=abcdefgh\n' > "$SCRATCH/score_b.txt"
    "$PRISM" diff --json "$SCRATCH/score_a.txt" "$SCRATCH/score_b.txt" > "$out" || s=$?
    cat "$out"
    (( s == 1 )) && file_has "$out" '{"kind":"insert","a":[0,0],"b":[0,1]}' '{"kind":"change","a":[0,1],"b":[1,2]'
}

eof_ws_ok() {
    local ws out s
    printf 'one\ntwo\n' > "$SCRATCH/eof_a.txt"
    printf 'one\ntwo' > "$SCRATCH/eof_b.txt"
    for ws in 0 1 2; do
        out="$SCRATCH/out/eof-$ws.txt"; s=0
        "$PRISM" diff --ws "$ws" "$SCRATCH/eof_a.txt" "$SCRATCH/eof_b.txt" > "$out" || s=$?
        echo "--ws $ws: exit $s"; cat "$out"
        (( s == 1 )) && file_has "$out" '\ No newline at end of file' || return 1
    done
    printf 'one\r\ntwo\r\n' > "$SCRATCH/eof_c.txt"
    exits_with 0 "$PRISM" diff --ws 1 "$SCRATCH/eof_a.txt" "$SCRATCH/eof_c.txt"
}

long_line_side_by_side() {
    /usr/bin/python3 -I -c '
import sys
line = "日本語のテキスト " * 400000
open(sys.argv[1], "w").write(line + "a\n")
open(sys.argv[2], "w").write(line + "b\n")' "$SCRATCH/long_a.txt" "$SCRATCH/long_b.txt"
}

merge_base_guard_ok() {
    swift test --filter 'mergesOfTwoGigabytesOrMoreAreRefused' 2>&1 | tee "$SCRATCH/out/merge-guard.log" \
        | grep -E '✘|✔ Test run|error:'
    grep -q '✔ Test run with 1 test' "$SCRATCH/out/merge-guard.log" && ! grep -q '✘' "$SCRATCH/out/merge-guard.log"
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
check "release build of prism" swift build -c release --product prism
BIN="$(swift build -c release --show-bin-path 2>/dev/null)"
PRISM="$BIN/prism"
echo "== binary: $PRISM"

# --- 1. global definition of done ---------------------------------------------
echo "-- 1. definition of done"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
check "DiffCore imports no Foundation" diffcore_foundation_free
check "no KS*/SF* identifiers in Sources or Tests" no_original_identifiers
check "DCO sign-off (check-dco.sh)" dco_check
check "CHANGELOG.md has an m02 entry" changelog_ok
check "docs/spec-public/prism-cli.md documents prism sniff and decoding" docs_ok
check "ci.yml runs M02.sh" ci_references

# --- 2. corpus classification -----------------------------------------------------
echo "-- 2. corpus classification"
check "encodings match encodings.sha256 (and are all listed)" manifest_ok
rows=0
while IFS=$'\t' read -r file kind enc bom endings; do
    [[ -z "$file" || "$file" == \#* ]] && continue
    rows=$((rows + 1))
    check "sniff $file: $kind $enc bom=$bom $endings" classified_as "$ENC/$file" "$kind" "$enc" "$bom" "$endings"
done < "$ENC/expected.tsv"
check "expected.tsv covers UTF-8±BOM, UTF-16LE/BE, Latin-1, Shift-JIS, mixed CRLF (>= 21 rows: $rows)" \
    test "$rows" -ge 21

# --- 3. round trip ------------------------------------------------------------------
echo "-- 3. round trip"
check "decode then encode is byte-identical for every text file (TextImportTests)" round_trip_ok
check "UTF-8 and UTF-8 with BOM compare equal" same_text "$ENC/utf8.txt" "$ENC/utf8-bom.txt"
check "UTF-16LE and UTF-16BE (BOM) compare equal" same_text "$ENC/utf16le-bom.txt" "$ENC/utf16be-bom.txt"
check "Latin-1 and BOM-less UTF-16LE compare equal" same_text "$ENC/latin1.txt" "$ENC/utf16le.txt"

# --- 4. binary ----------------------------------------------------------------------
echo "-- 4. binary"
# Image files may not be committed (check-cleanroom.sh), so the PNG fixture
# is stored as .bin and also checked under a .png name.
cp "$ENC/image-png.bin" "$SCRATCH/pixels.png"
for file in "$ENC/image-png.bin" "$SCRATCH/pixels.png" "$ENC/archive.zip" "$ENC/macho.bin" "$PRISM" /usr/bin/true; do
    check "sniff reports binary: $file" reports_binary "$file"
    check "prism diff refuses $file (exit 2, message)" refused "$file"
done
check "prism merge3 refuses a binary input (exit 2)" \
    exits_with 2 "$PRISM" merge3 "$ENC/utf8.txt" "$ENC/image-png.bin" "$ENC/utf8.txt"

# --- 5. documents ---------------------------------------------------------------------
echo "-- 5. documents"
for format in rtf pdf docx odt doc; do
    check "doc.$format gives the expected text" document_text "$format"
done

# --- 6. large-file import ----------------------------------------------------------------
echo "-- 6. large-file import (scale $SCALE)"
: > "$ACCEPT_DIR/perf.txt"
check "make 100 MB inputs (UTF-8, Latin-1, UTF-16)" make_big
check "100 MB UTF-8 classified (1.9M lines)" big_classified "$SCRATCH/big-utf8.txt" utf-8
check "100 MB UTF-8 import <= 1000 ms x $SCALE" within_budget utf8 1000 "$PRISM" sniff "$SCRATCH/big-utf8.txt"
check "100 MB ISO-8859-1 import <= 1000 ms x $SCALE" within_budget latin1 1000 "$PRISM" sniff "$SCRATCH/big-latin1.txt"
check "200 MB UTF-16LE (100 MB of text) import <= 1500 ms x $SCALE" \
    within_budget utf16 1500 "$PRISM" sniff "$SCRATCH/big-utf16.txt"

# --- 7. prism sniff --------------------------------------------------------------------------
echo "-- 7. prism sniff"
check "prism --help lists sniff as available" help_lists_sniff
check "sniff report: key: value lines, blank line between files, missing" sniff_text_ok
check "sniff reads standard input" sniff_stdin_ok
check "sniff classifies a folder" sniff_folder_ok
check "sniff without files exits 2" exits_with 2 "$PRISM" sniff
check "sniff of an unreadable file exits 2 and still reports the others" sniff_unreadable_ok

# --- 8. carry-overs from M1 ----------------------------------------------------------------------
echo "-- 8. carry-overs"
check "CJK change highlights one character (word boundaries)" cjk_words_ok
check "line pairing scores characters, not bytes" char_scoring_ok
check "final-newline difference shows at --ws 0, 1 and 2" eof_ws_ok
check "make two 3.6 MB single-line CJK files" long_line_side_by_side
check "side-by-side of the long lines <= 1500 ms x $SCALE (truncate before layout)" \
    within_budget side-by-side 1500 "$PRISM" diff --side-by-side --width 120 "$SCRATCH/long_a.txt" "$SCRATCH/long_b.txt"
check "merge3 refuses a base of 2 GiB or more (Merge3Tests)" merge_base_guard_ok

# --- 9. hygiene -------------------------------------------------------------------------------------
echo "-- 9. hygiene"
check "git status unchanged by the run" worktree_unchanged

accept_summary
