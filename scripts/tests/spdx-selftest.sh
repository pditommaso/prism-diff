#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Self-test for scripts/ci/check-spdx.sh: builds scratch git repositories
# and checks which files the guard accepts. In particular, a Swift file
# under Tests/corpus/fixtures/ is exempt only while it is pinned (path and
# sha256) in Tests/corpus/fixtures.sha256.
# Exit status: 0 when every case behaves as expected, 1 otherwise.
set -uo pipefail

guard="$(cd "$(dirname "$0")/../ci" && pwd)/check-spdx.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/prism-spdx.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
failures=0

new_repo() {
    rm -rf "$repo"
    mkdir -p "$repo/scripts/ci" "$repo/Tests/corpus/fixtures/text"
    cp "$guard" "$repo/scripts/ci/check-spdx.sh"
    printf 'let a = 1\n' > "$repo/Tests/corpus/fixtures/text/a.swift"
    (cd "$repo/Tests/corpus" && shasum -a 256 fixtures/text/a.swift > fixtures.sha256)
    git -C "$repo" init -q
}

expect() {  # expect <pass|fail> <description>
    local got=pass
    bash "$repo/scripts/ci/check-spdx.sh" >/dev/null 2>&1 || got=fail
    if [[ "$got" == "$1" ]]; then
        echo "ok    $2"
    else
        echo "not ok $2 (got $got, want $1)"
        failures=$((failures + 1))
    fi
}

new_repo; expect pass "pinned fixture without header is exempt"
new_repo; printf 'let b = 2\n' > "$repo/Tests/corpus/fixtures/text/b.swift"
expect fail "unpinned Swift file under fixtures/ needs a header"
new_repo; printf 'let a = 2\n' > "$repo/Tests/corpus/fixtures/text/a.swift"
expect fail "edited pinned fixture needs a header"
new_repo; printf 'let c = 3\n' > "$repo/main.swift"
expect fail "Swift source without header"
new_repo; printf '// SPDX-License-Identifier: Apache-2.0\nlet c = 3\n' > "$repo/main.swift"
expect fail "Swift source without copyright line"
new_repo; printf '// SPDX-License-Identifier: Apache-2.0\n// Copyright 2026 Paolo Di Tommaso\nlet c = 3\n' > "$repo/main.swift"
expect pass "Swift source with both header lines"

if (( failures > 0 )); then
    echo "spdx-selftest: $failures failure(s)"
    exit 1
fi
echo "spdx-selftest: OK"
