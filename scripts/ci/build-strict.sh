#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Strict build gate: release build, debug build of all test targets, then the
# test suite.
#
# Compiler warnings are made fatal with -warnings-as-errors. Grepping the
# output alone is not enough: the Swift driver reports warnings only for the
# files it recompiles, so a warm build cache would hide an existing warning.
# A file with a warning now never compiles successfully, so it is rebuilt
# (and fails) on every run. The output is still scanned, to catch linker
# warnings, allowing only the linker search-path notices that the Command
# Line Tools emit for every link, even in an empty package (environmental,
# not our code).
#
# PRISM_STRICT_PACKAGE_DIR overrides the package directory (default: the
# repository root); scripts/tests/build-strict-selftest.sh uses it.
#
# The swift-testing plugin path needed by the Swift 6.4 Command Line Tools is
# set in Package.swift, so plain `swift test` works here and by hand alike.
#
# Logs: build/logs/{build-release,build-tests,test}.log
# Exit status: 0 when the build is clean and all tests pass, 1 otherwise.
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "${PRISM_STRICT_PACKAGE_DIR:-$repo_root}"

readonly LOG_DIR=build/logs
mkdir -p "$LOG_DIR"

# Fatal compiler warnings, for every build and test invocation alike (the
# same flags let `swift test` reuse the build-tests products).
readonly STRICT=(-Xswiftc -warnings-as-errors)

# Exact linker notices allowed through; nothing broader.
readonly ALLOWED=(
    "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found"
    "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found"
)

# Runs a command, tees its output to a log and returns its exit status.
run_logged() {
    local log="$1"; shift
    echo "==> $*"
    set +e
    "$@" 2>&1 | tee "$log"
    local status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

# Prints the warning/error lines of a log that are not allowlisted.
# Returns 0 when there are none.
check_log() {
    local log="$1" line allowed ok bad=0
    while IFS= read -r line; do
        ok=0
        for allowed in "${ALLOWED[@]}"; do
            [[ "$line" == *": $allowed" || "$line" == "$allowed" ]] && { ok=1; break; }
        done
        if (( ! ok )); then
            echo "  $line"
            bad=1
        fi
    done < <(sed -E $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E 'warning:|error:' || true)
    return "$bad"
}

failed=0

gate() {
    local name="$1"; shift
    local log="$LOG_DIR/$name.log"
    if ! run_logged "$log" "$@"; then
        echo "FAIL: $name exited non-zero (see $log)"
        failed=1
        return 0
    fi
    if ! check_log "$log" > "$LOG_DIR/$name.offending"; then
        echo "FAIL: $name produced warnings or errors:"
        cat "$LOG_DIR/$name.offending"
        failed=1
    else
        echo "OK: $name is warning-free"
    fi
    rm -f "$LOG_DIR/$name.offending"
}

gate build-release swift build -c release "${STRICT[@]}"
gate build-tests swift build --build-tests "${STRICT[@]}"

# CI runners have no usable display and few CPUs: PRISM_CI_SKIP_APP_TESTS=1
# skips the AppKit app tests and three timing-sensitive tests there. They run
# in full on a developer machine (their windows stay invisible).
TEST_SKIPS=()
if [[ "${PRISM_CI_SKIP_APP_TESTS:-}" == "1" ]]; then
    TEST_SKIPS=(--skip PrismAppTests
                --skip 'cancellingTheTaskCancelsAnAsyncDiff|aTricklingClientIsCutOffAtTheDeadline|appIsLaunchedWhenNotRunning')
    echo "notice: PRISM_CI_SKIP_APP_TESTS=1: app and timing-sensitive tests skipped"
fi
if run_logged "$LOG_DIR/test.log" swift test "${STRICT[@]}" ${TEST_SKIPS[@]+"${TEST_SKIPS[@]}"}; then
    echo "OK: swift test passed"
else
    echo "FAIL: swift test failed (see $LOG_DIR/test.log)"
    failed=1
fi

if (( failed )); then
    echo "build-strict: FAILED"
    exit 1
fi
echo "build-strict: OK"
