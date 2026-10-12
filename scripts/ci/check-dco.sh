#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Developer Certificate of Origin check.
# Usage: scripts/ci/check-dco.sh [RANGE]
#   RANGE defaults to master..HEAD (falling back to origin/master..HEAD when no
#   local main branch exists, as in CI checkouts).
# Every non-merge commit in RANGE must carry a trailer
#   Signed-off-by: Name <email>
# whose e-mail matches the commit author's e-mail (case-insensitive).
# Exit status: 0 when all commits are signed off, 1 otherwise.
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

if (( $# > 1 )); then
    echo "usage: $0 [RANGE]" >&2
    exit 2
fi

if (( $# == 1 )); then
    range=$1
elif git rev-parse -q --verify 'master^{commit}' >/dev/null; then
    range=master..HEAD
elif git rev-parse -q --verify 'origin/master^{commit}' >/dev/null; then
    range=origin/master..HEAD
else
    echo "check-dco: cannot find 'master' or 'origin/master'; pass a RANGE" >&2
    exit 2
fi

commits=$(git rev-list --no-merges "$range")

total=0
offenders=0
for sha in $commits; do
    total=$((total + 1))
    email=$(git log -1 --format='%ae' "$sha")
    lc_email=$(tr '[:upper:]' '[:lower:]' <<<"$email")
    signed=0
    while IFS= read -r line; do
        # Expected shape: "Signed-off-by: Name <email>"
        if [[ "$line" =~ ^Signed-off-by:\ .+\ \<([^\>]+)\>[[:space:]]*$ ]]; then
            found=$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")
            if [[ "$found" == "$lc_email" ]]; then
                signed=1
                break
            fi
        fi
    done < <(git log -1 --format='%B' "$sha")
    if (( signed == 0 )); then
        echo "missing sign-off for <$email>: $(git log -1 --format='%h %s' "$sha")"
        offenders=$((offenders + 1))
    fi
done

if (( offenders > 0 )); then
    echo "check-dco: FAIL ($offenders of $total commits in $range lack a matching Signed-off-by)"
    echo "Fix with 'git commit --amend -s' or 'git rebase --signoff <base>'."
    exit 1
fi
echo "check-dco: OK ($total commits in $range signed off)"
