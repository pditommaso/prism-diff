#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Checks that scripts/ci/build-strict.sh fails on a compiler warning even
# when the build cache is warm, i.e. when an earlier ordinary build already
# compiled the offending file and a plain rebuild would print nothing.
# Also checks that the same package without the warning passes both build
# gates. Uses a throwaway package in a temporary directory.
# Exit status: 0 when both hold, 1 otherwise.
set -uo pipefail

script="$(cd "$(dirname "$0")/../ci" && pwd)/build-strict.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/prism-strict-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT

make_package() {    # make_package <dir> <body of f()>
    mkdir -p "$1/Sources/Lib"
    cat > "$1/Package.swift" <<'EOF'
// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "Lib", targets: [.target(name: "Lib")])
EOF
    printf 'public func f() -> Int {\n%s\n}\n' "$2" > "$1/Sources/Lib/Lib.swift"
}

failures=0
fail() { echo "not ok: $*"; failures=$((failures + 1)); }

# 1. A warning hidden by a warm cache must still fail the gate.
make_package "$work/warn" '    let unused = 1
    return 2'
( cd "$work/warn" && swift build -c release >/dev/null 2>&1 && swift build --build-tests >/dev/null 2>&1 ) \
    || fail "warm-up builds of the warning package failed"
out=$(PRISM_STRICT_PACKAGE_DIR="$work/warn" bash "$script" 2>&1)
status=$?
if (( status != 0 )) && grep -q '^FAIL: build-release' <<<"$out" \
        && grep -q '^FAIL: build-tests' <<<"$out"; then
    echo "ok: warm-cache warning fails build-release and build-tests"
else
    fail "warm-cache warning was not caught (exit $status)"
    sed 's/^/    /' <<<"$out"
fi

# 2. The same package without the warning passes both build gates (its
# swift test step fails for lack of tests, which is not under test here).
make_package "$work/clean" '    return 2'
out=$(PRISM_STRICT_PACKAGE_DIR="$work/clean" bash "$script" 2>&1)
if grep -q '^OK: build-release is warning-free' <<<"$out" \
        && grep -q '^OK: build-tests is warning-free' <<<"$out"; then
    echo "ok: warning-free package passes both build gates"
else
    fail "warning-free package did not pass the build gates"
    sed 's/^/    /' <<<"$out"
fi

(( failures == 0 )) && echo "build-strict-selftest: OK" || echo "build-strict-selftest: $failures failure(s)"
(( failures == 0 ))
