#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Headless accessibility audit (M11): never launches Prism.app.
# Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/a11y-audit.sh
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh
#
# What it covers:
#   VoiceOver: the windows of every scope (launch, text with find bar,
#   shelf and tabs, folder, changeset, three-way merge in each layout,
#   Integration, Settings, About, Help) are built offscreen and their
#   accessibility hierarchy walked; no interactive element may be
#   unnamed, and the key names (tab strip, breadcrumbs, merge arrows,
#   gutter buttons, find bar) are checked one by one        -> 1
#   keyboard-only operation: launch window, tab focus, key view loop,
#   shortcuts for the essential commands                     -> 1
#   Increase Contrast and Reduce Motion                      -> 1, 2
#   Help, README and the non-affiliation notice              -> 1, 3
#
# Output of every check: build/accept/a11y-audit/checks.log.
set -uo pipefail

# Headless by definition: no GUI check, whatever the machine allows.
export CI=true

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init a11y-audit

SCRATCH="$(mktemp -d)"
readonly SCRATCH
trap 'accept_cleanup; rm -rf "$SCRATCH"' EXIT

# swift_tests <filter> <minimum count>: runs the matching tests; all must
# pass and at least <minimum> must run.
swift_tests() {
    local filter="$1" minimum="$2" log="$SCRATCH/tests-$RANDOM.log" ran
    swift test --filter "$filter" > "$log" 2>&1
    grep -E '✘|✔ Test run|error:' "$log"
    grep -q '✔ Test run with' "$log" && ! grep -q '✘' "$log" || return 1
    ran=$(grep -oE 'Test run with [0-9]+ test' "$log" | grep -oE '[0-9]+' | head -n 1)
    echo "tests run: ${ran:-0} (want >= $minimum)"
    (( ${ran:-0} >= minimum ))
}

file_has() {        # file_has <file> <fixed string>...
    local file="$1" s; shift
    [[ -f "$file" ]] || { echo "missing: $file"; return 1; }
    for s in "$@"; do
        grep -Fq -- "$s" "$file" || { echo "$file lacks: $s"; return 1; }
    done
}

no_animation_apis() {
    ! grep -rnE '\.animator\(\)|runAnimationGroup|allowsImplicitAnimation = true|NSViewAnimation|CABasicAnimation|animates = true' \
        Sources/PrismApp
}

readme_ok() {
    file_has README.md \
        "Prism is an independent open-source project, not affiliated with Kaleidoscope." \
        "The \`prism\` command accepts the same options as \`ksdiff\` for compatibility." \
        "xattr -dr com.apple.quarantine /Applications/Prism.app" "right-click" \
        "Prism > Integration" "Contents/Helpers/prism" \
        "difftool.prism.cmd" "mergetool.prism.cmd" "mergetool.prism.trustExitCode" \
        "Command Line Tools only" "Apache License" "## Screenshots"
}

spec_public_ok() {
    local bad
    bad=$(git ls-files docs/spec-public | grep -v '\.md$')
    [[ -z "$bad" ]] || { echo "not Markdown: $bad"; return 1; }
    git ls-files docs/spec-public
}

# --- 0. build ------------------------------------------------------------------
echo "-- 0. build"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
else
    check "release build zero warnings + swift test (build-strict.sh, logs in build/logs)" scripts/ci/build-strict.sh
fi

# --- 1. unit tests -------------------------------------------------------------------
echo "-- 1. tests"
check "VoiceOver labels in every scope, keyboard operation (AccessibilityAuditTests)" \
    swift_tests AccessibilityAuditTests 13
check "Increase Contrast and Reduce Motion (DisplayOptionsTests)" swift_tests DisplayOptionsTests 7
check "Help topics, shortcut list, Help window, non-affiliation notice (HelpTests)" swift_tests HelpTests 6

# --- 2. static guards ----------------------------------------------------------------
echo "-- 2. guards"
check "no animation APIs in the app sources (Reduce Motion: nothing animates)" no_animation_apis
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh

# --- 3. documentation ----------------------------------------------------------------
echo "-- 3. docs"
check "README: install (quarantine), prism links, git setup, CLT build, licence, notice" readme_ok
check "docs/spec-public holds Markdown only" spec_public_ok

accept_summary
