#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Self-test for scripts/ci/check-cleanroom.sh: plants one violation at a
# time in a scratch git repository and expects the guard to reject it, and
# expects a clean scratch repository to pass.
# Exit status: 0 when every case behaves as expected, 1 otherwise.
set -uo pipefail

guard="$(cd "$(dirname "$0")/../ci" && pwd)/check-cleanroom.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/prism-cleanroom.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
failures=0

# new_repo: fresh scratch repo holding only the guard and a clean source file.
new_repo() {
    rm -rf "$scratch/repo"
    mkdir -p "$scratch/repo/scripts/ci" "$scratch/repo/Sources"
    cp "$guard" "$scratch/repo/scripts/ci/check-cleanroom.sh"
    printf 'let greeting = "hello"\n' > "$scratch/repo/Sources/main.swift"
    git -C "$scratch/repo" init -q
}

# expect <pass|fail> <description> [env assignments...]
expect() {
    local want="$1" description="$2"; shift 2
    local got=pass
    env "$@" bash "$scratch/repo/scripts/ci/check-cleanroom.sh" >/dev/null 2>&1 || got=fail
    if [[ "$got" == "$want" ]]; then
        echo "ok    $description"
    else
        echo "not ok $description (got $got, want $want)"
        failures=$((failures + 1))
    fi
}

plant() {   # plant <path> <content>
    mkdir -p "$(dirname "$scratch/repo/$1")"
    printf '%s\n' "$2" > "$scratch/repo/$1"
}

new_repo; expect pass "clean repository passes"
new_repo; plant Sources/a.swift 'class K''SView {}';            expect fail "KS-prefixed class name"
new_repo; plant Sources/a.swift 'let x = _K''SView()';          expect fail "underscore before KS prefix"
new_repo; plant Sources/a.swift 'let x = fooS''FWindow()';      expect fail "lowercase before SF prefix"
new_repo; plant Sources/a.swift 'let TASKS = 1';              expect pass "all-caps word containing KS"
new_repo; plant Sources/K''SDiffView.swift 'let a = 1';         expect fail "KS-prefixed file name"
new_repo; plant Sources/S''FViews/a.swift 'let a = 1';          expect fail "SF-prefixed directory name"
new_repo; plant Tests/corpus/reference/x.txt 'x';             expect fail "nested reference/ directory"
new_repo; plant docs/Spec/x.md 'x';                           expect fail "docs/Spec/ (same as docs/spec/ on macOS)"
new_repo; plant Reference/x.txt 'x';                          expect fail "Reference/ in another case"
new_repo; plant notes/Observations.md 'x';                    expect fail "private notes name in another case"
new_repo; plant scripts/accept/docs/spec/x.md 'x';            expect fail "nested docs/spec/ directory"
new_repo; plant Tests/data/menus-file.txt 'x';                expect fail "private menu dump file name"
new_repo; plant scripts/accept/screens/foo.png 'x';           expect fail "png outside docs/"
new_repo; plant Resources/icon.icns 'x';                      expect fail "icns image"
new_repo; plant Tests/shot.TIFF 'x';                          expect fail "tiff image"
new_repo; plant Sources/a.swift 'let n = "Kal''eidoscope"';    expect fail "other product name in code"
new_repo; plant docs/notes.md 'by Black Pi''xel';             expect fail "other vendor name"
new_repo; plant README.md 'a re-implementation of Kal''eidoscope'; expect pass "name allowed in README.md"
new_repo; plant CONTRIBUTING.md 'not affiliated with Kal''eidoscope'; expect pass "name allowed in CONTRIBUTING.md"
new_repo; plant Sources/a.swift 'open("di''ff://x")';         expect fail "foreign URL scheme"

# Content copy of a private file under an innocent path.
mkdir -p "$scratch/dirty/reference/notes"
printf 'private observation 42\n' > "$scratch/dirty/reference/notes/obs.txt"
new_repo; plant Tests/data/notes.txt 'private observation 42'
expect fail "byte-identical copy of a private note" PRISM_DIRTY_ROOT="$scratch/dirty"
expect pass "same file passes without PRISM_DIRTY_ROOT"

if (( failures > 0 )); then
    echo "cleanroom-selftest: $failures failure(s)"
    exit 1
fi
echo "cleanroom-selftest: OK"
