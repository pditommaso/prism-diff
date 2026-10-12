#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Verifies that every source file carries an SPDX licence header.
#   *.swift, *.sh, *.py, *.yml, *.yaml: "SPDX-License-Identifier: Apache-2.0"
#                                      within the first 3 lines
#   *.swift additionally:              "Copyright 2026 Paolo Di Tommaso"
#                                      within the first 3 lines
# Checks tracked files plus untracked files that are not ignored.
# Deliberate deviation: the synthetic diff inputs under Tests/corpus/fixtures/
# carry no header, because a header would shift the line numbers that
# acceptance criteria refer to (see Tests/corpus/README.md). Only files that
# are pinned, path and sha256, in Tests/corpus/fixtures.sha256 are exempt:
# a new or edited file under fixtures/ is checked like any other until it is
# reviewed and added to the manifest.
# Exit status: 0 when all files comply, 1 otherwise.
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

readonly SPDX='SPDX-License-Identifier: Apache-2.0'
readonly COPYRIGHT='Copyright 2026 Paolo Di Tommaso'

readonly MANIFEST=Tests/corpus/fixtures.sha256

offenders=0
checked=0
exempt=0

# "<sha256>  Tests/corpus/<path>" lines of the pinned fixtures.
pinned=""
if [[ -f "$MANIFEST" ]]; then
    pinned=$(awk 'NF == 2 { print $1 "  Tests/corpus/" $2 }' "$MANIFEST")
fi

# is_pinned <file>: the file's path and content match a manifest entry.
is_pinned() {
    local hash
    [[ -n "$pinned" ]] || return 1
    hash=$(shasum -a 256 -- "$1" | cut -d' ' -f1)
    grep -Fxq -- "$hash  $1" <<<"$pinned"
}

while IFS= read -r -d '' file; do
    case "$file" in
        *.swift|*.sh|*.py|*.yml|*.yaml) ;;
        *) continue ;;
    esac
    # Tracked files deleted from the working tree are still listed; skip them.
    [[ -f "$file" ]] || continue
    if [[ "$file" == Tests/corpus/fixtures/* ]] && is_pinned "$file"; then
        exempt=$((exempt + 1))
        continue
    fi
    checked=$((checked + 1))

    header=$(head -n 3 -- "$file")
    if [[ "$header" != *"$SPDX"* ]]; then
        echo "missing SPDX header: $file"
        offenders=$((offenders + 1))
        continue
    fi
    if [[ "$file" == *.swift && "$header" != *"$COPYRIGHT"* ]]; then
        echo "missing copyright line: $file"
        offenders=$((offenders + 1))
    fi
done < <(git ls-files -z -co --exclude-standard)

if (( offenders > 0 )); then
    echo "check-spdx: FAIL ($offenders of $checked files lack a valid header)"
    exit 1
fi
echo "check-spdx: OK ($checked files checked, $exempt pinned corpus fixtures exempt)"
