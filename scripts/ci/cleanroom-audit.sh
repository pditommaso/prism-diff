#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Clean-room audit (M11). Complements check-cleanroom.sh, which looks for
# patterns, with two content checks:
#
#   1. Strings. scripts/ci/cleanroom-hashes.txt lists SHA-256 hashes of
#      distinctive UI strings and identifiers of the product Prism must not
#      copy, after normalisation (below). The list holds hashes only, so it
#      reveals nothing. The audit compares against it:
#        - every string literal in the repository ("...", '...', `...`),
#          as a whole;
#        - every run of 1 to N consecutive words of every text file, read
#          as one word stream (so a phrase split across lines or embedded
#          in a longer sentence is found too). N is the "max-words" value
#          in the hash file.
#   2. Assets. When PRISM_REFERENCE_SCREENS names a folder of reference
#      screenshots (kept outside the repository; its path is never stored
#      here), no file in the repository, and no file of a built
#      build/Prism.app or build/AppIcon.icns, may have the SHA-256 of any
#      file in it. Without the variable the asset check is skipped with a
#      notice; the CI runners have no reference material.
#
# Normalisation (identical when the list is built and when it is checked):
# Unicode NFKC, lower case, apostrophes removed, then only the runs of
# [a-z0-9] are kept, joined by single spaces. "Don’t Resolve…" becomes
# "dont resolve". The hash is SHA-256 of that UTF-8 text.
#
# Scope: tracked files plus untracked files that are not ignored. Binary
# files are skipped by the string check.
#
# Building the list (maintainers with access to the private research notes):
#   scripts/ci/cleanroom-audit.sh --hash < plaintext-list > hashes
# prints "<sha256>" per non-empty input line and a "max-words" line; see
# the header of cleanroom-hashes.txt for how the plaintext was chosen.
#
# Usage: scripts/ci/cleanroom-audit.sh [--hash]
# Environment: PRISM_REFERENCE_SCREENS (optional, see above),
#              PRISM_AUDIT_HASHES (optional, another hash file; self-test).
# Exit status: 0 with 0 matches, 1 on any match, 2 on a usage error.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

readonly PY=/usr/bin/python3
readonly AUDIT_PY=scripts/ci/cleanroom_audit.py
HASHES="${PRISM_AUDIT_HASHES:-scripts/ci/cleanroom-hashes.txt}"

if [[ "${1:-}" == --hash ]]; then
    exec "$PY" -I "$AUDIT_PY" hash
fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--hash]" >&2; exit 2; }
[[ -f "$HASHES" ]] || { echo "cleanroom-audit: missing $HASHES" >&2; exit 2; }

status=0

# 1. Strings.
string_status=0
git ls-files -co --exclude-standard -z | "$PY" -I "$AUDIT_PY" check "$HASHES" || string_status=$?
(( string_status == 2 )) && exit 2
(( string_status == 0 )) || status=1

# 2. Assets.
if [[ -z "${PRISM_REFERENCE_SCREENS:-}" ]]; then
    echo "cleanroom-audit: assets: skipped (PRISM_REFERENCE_SCREENS not set)"
elif [[ ! -d "$PRISM_REFERENCE_SCREENS" ]]; then
    echo "cleanroom-audit: assets: PRISM_REFERENCE_SCREENS is not a directory"
    status=1
else
    reference=$(find "$PRISM_REFERENCE_SCREENS" -type f -size +0 -exec shasum -a 256 {} + | cut -d' ' -f1 | sort -u)
    count=$(grep -c . <<<"$reference" || true)
    checked=0 asset_matches=0
    while IFS= read -r -d '' path; do
        [[ -f "$path" && -s "$path" ]] || continue
        checked=$((checked + 1))
        hash=$(shasum -a 256 "$path" | cut -d' ' -f1)
        if grep -Fxq "$hash" <<<"$reference"; then
            echo "$path: identical to a reference screenshot"
            asset_matches=$((asset_matches + 1))
        fi
    done < <(
        git ls-files -co --exclude-standard -z
        for built in build/Prism.app build/AppIcon.icns; do
            [[ -e "$built" ]] && find "$built" -type f -print0
        done
    )
    echo "cleanroom-audit: assets: $checked files against $count reference hashes, $asset_matches matches"
    (( asset_matches == 0 )) || status=1
fi

if (( status == 0 )); then
    echo "cleanroom-audit: OK (0 matches)"
else
    echo "cleanroom-audit: FAIL"
fi
exit "$status"
