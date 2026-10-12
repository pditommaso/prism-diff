#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Self-test for scripts/ci/cleanroom-audit.sh: a scratch git repository with
# the audit and a hash list of made-up phrases; plants one match at a time
# and expects the audit to report it, and a clean repository to pass.
# Exit status: 0 when every case behaves as expected, 1 otherwise.
set -uo pipefail

ci="$(cd "$(dirname "$0")/../ci" && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/prism-audit.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
failures=0

mkdir -p "$scratch/screens"
printf 'not really a png\n' > "$scratch/screens/shot.png"

new_repo() {
    rm -rf "$scratch/repo"
    mkdir -p "$scratch/repo/scripts/ci" "$scratch/repo/Sources"
    cp "$ci/cleanroom-audit.sh" "$ci/cleanroom_audit.py" "$scratch/repo/scripts/ci/"
    git -C "$scratch/repo" init -q
    printf 'Purple Walrus Umbrella\nMagenta\xe2\x80\xa6 Teapot\nZQX42Widget\n' \
        | "$scratch/repo/scripts/ci/cleanroom-audit.sh" --hash > "$scratch/repo/scripts/ci/cleanroom-hashes.txt"
    printf 'let greeting = "hello"\n' > "$scratch/repo/Sources/main.swift"
}

# expect <pass|fail> <description> [env assignments...]
expect() {
    local want="$1" description="$2"; shift 2
    local got=pass
    env "$@" bash "$scratch/repo/scripts/ci/cleanroom-audit.sh" >"$scratch/out" 2>&1 || got=fail
    if [[ "$got" == "$want" ]]; then
        echo "ok    $description"
    else
        echo "not ok $description (got $got, want $want)"
        sed 's/^/      /' "$scratch/out"
        failures=$((failures + 1))
    fi
}

plant() {   # plant <path> <content>
    mkdir -p "$(dirname "$scratch/repo/$1")"
    printf '%s\n' "$2" > "$scratch/repo/$1"
}

new_repo; expect pass "clean repository passes"
new_repo; plant Sources/a.swift 'let t = "Purple Walrus Umbrella"';   expect fail "exact string literal"
new_repo; plant Sources/a.swift "let t = 'purple  walrus umbrella!'"; expect fail "case, spacing and punctuation ignored"
new_repo; plant README.md 'Click the purple walrus
umbrella to start.';                                                   expect fail "phrase split across lines"
new_repo; plant Sources/a.swift 'let t = "Magenta... Teapot"';        expect fail "ASCII dots for the ellipsis"
new_repo; plant Sources/a.swift 'final class ZQX42Widget {}';         expect fail "listed identifier"
new_repo; plant Sources/a.swift 'let t = "Purple Walrus"';            expect pass "a shorter phrase is not a match"
new_repo; plant Sources/a.swift 'let t = "ZQX42Widgets"';             expect pass "a longer word is not a match"
new_repo; cp "$scratch/screens/shot.png" "$scratch/repo/Sources/copy.dat"
expect fail "asset identical to a reference screenshot" PRISM_REFERENCE_SCREENS="$scratch/screens"
new_repo; expect pass "assets differ from the reference" PRISM_REFERENCE_SCREENS="$scratch/screens"
new_repo; expect fail "reference folder missing" PRISM_REFERENCE_SCREENS="$scratch/missing"
new_repo; printf 'not a hash\n' > "$scratch/repo/scripts/ci/cleanroom-hashes.txt"
expect fail "malformed hash list"

if (( failures > 0 )); then
    echo "cleanroom-audit-selftest: FAIL ($failures case(s))"
    exit 1
fi
echo "cleanroom-audit-selftest: OK"
