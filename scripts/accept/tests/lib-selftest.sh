#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Self-test for scripts/accept/lib.sh.
#
#   lib-selftest.sh         helper logic only (no app needed)
#   lib-selftest.sh --app   also drives build/Prism.app: launch, native
#                           arch, About window shown at launch, capture
#                           and quit
#
# Exit status: 0 when every assertion holds, 1 otherwise.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../lib.sh"
failures=0

assert() {
    local description="$1"; shift
    if "$@"; then
        echo "ok    $description"
    else
        echo "not ok $description"
        failures=$((failures + 1))
    fi
}

# Runs a snippet in a fresh bash that has sourced lib.sh; prints its output.
in_lib() {
    bash -c "source '$lib'; $1" 2>&1
}

# --- helper logic ---

assert "lib.sh refuses to be executed" bash -c "! bash '$lib' >/dev/null 2>&1"

out=$(in_lib 'PRISM_ACCEPT_HEADLESS=1; accept_init selftest-pass; check "true passes" true; accept_summary')
status=$?
assert "summary exits 0 when all checks pass" test "$status" -eq 0
assert "a passing check prints PASS" grep -q '^PASS  true passes$' <<<"$out"
assert "summary reports the totals" grep -q '1/1 checks passed' <<<"$out"

out=$(in_lib 'set -e; PRISM_ACCEPT_HEADLESS=1; accept_init selftest-fail
check "first fails" sh -c "echo boom; exit 3"
check "second passes" true
accept_summary')
status=$?
assert "summary exits 1 when a check fails" test "$status" -eq 1
assert "a failing check prints FAIL with its status" grep -q '^FAIL  first fails (exit 3)$' <<<"$out"
assert "a failing check shows its output" grep -q '^      boom$' <<<"$out"
assert "a failure does not abort later checks under set -e" grep -q '^PASS  second passes$' <<<"$out"
assert "failed checks are listed" grep -q 'failed: first fails' <<<"$out"
assert "check output is logged" grep -q '^boom$' "$(git -C "$here" rev-parse --show-toplevel)/build/accept/selftest-fail/checks.log"

assert "CI=true selects headless mode" bash -c "CI=true; source '$lib'; ! gui_available"
assert "with_timeout kills a slow command" bash -c "source '$lib'; ! (with_timeout 1 sleep 5) 2>/dev/null"
assert "with_timeout passes a fast command" bash -c "source '$lib'; with_timeout 5 true"
assert "wait_until times out" bash -c "source '$lib'; ! wait_until 1 false"
assert "AppleScript strings are escaped" \
    test "$(in_lib '_as_string "say \"hi\" \\ bye"')" = '"say \"hi\" \\ bye"'
assert "winlist builds and reports usage errors" bash -c "source '$lib'; winlist >/dev/null 2>&1; test \$? -eq 2"
assert "keypost builds and reports usage errors" bash -c "source '$lib'; keypost >/dev/null 2>&1; test \$? -eq 2"
assert "keypost rejects an unknown modifier" bash -c "source '$lib'; keypost 1 13 hyper >/dev/null 2>&1; test \$? -eq 2"
assert "lib.sh never types with System Events keystroke" bash -c "! grep -En '^[^#]*keystroke' '$lib'"

# app_window_closed with stubbed app_running / ax_window_titles.
closed() {  # closed <running 0|1> <query status> <titles>
    bash -c "source '$lib'
        app_running() { return $1; }
        ax_window_titles() { printf '%s\n' '$3'; return $2; }
        app_window_closed 'About Prism'" >/dev/null 2>&1
}
not_closed() { ! closed "$@"; }
assert "window closed: app answers without the title" closed 0 0 "Other"
assert "window not closed: title still listed" not_closed 0 0 "About Prism"
assert "window not closed: window query fails" not_closed 0 1 ""
assert "window not closed: app is gone" not_closed 1 0 ""

if [[ "${1:-}" != "--app" ]]; then
    (( failures == 0 )) && { echo "lib-selftest: OK"; exit 0; }
    echo "lib-selftest: $failures failure(s)"; exit 1
fi

# --- app flow ---

# shellcheck source=../lib.sh
source "$lib"
accept_init selftest-app
if app_running; then
    echo "lib-selftest: build/Prism.app is already running; quit it first" >&2
    exit 1
fi
check "launch Prism.app" app_launch
check "app runs natively (ARM64)" app_is_native
check "About window appears at launch" app_wait_window "About Prism" 10
check "capture About window" capture about "About Prism"
check "quit Prism.app" app_quit
check "no Prism.app process left" bash -c "source '$lib'; ! app_running"

# An instance this shell did not launch through app_launch must survive
# app_quit and the exit trap of another script (they target ACCEPT_APP_PID).
check "start an instance outside app_launch" bash -c "open -n '$ACCEPT_APP' --args --no-about && source '$lib' && wait_until 15 app_running"
check "app_quit in another shell leaves it running" \
    bash -c "source '$lib'; app_quit; accept_cleanup; sleep 1; app_running"
ACCEPT_APP_PID=$(app_pid)
check "quit it by its PID" app_quit
check "no Prism.app process left" bash -c "source '$lib'; ! app_running"
(( failures == 0 )) || { echo "lib-selftest: $failures helper failure(s)"; ACCEPT_FAIL=$((ACCEPT_FAIL + failures)); }
accept_summary
