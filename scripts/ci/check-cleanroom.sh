#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Clean-room guard. Fails when the repository shows signs of material that
# must never be published (see CONTRIBUTING.md and docs/spec-public/README.md):
#   a) identifiers that look like another product's class names: (KS|SF)[A-Z]
#      not preceded by a capital letter (so `_KSView` and `fooKSView` count),
#      in file contents and in file and directory names
#   b) any image file, except Prism's own screenshots in docs/screenshots/
#      (reference screenshots of the original never enter the repo; the app
#      icon is drawn at build time; cleanroom-audit.sh hash-checks every image)
#   c) any path with a reference/ or docs/spec/ directory component, at any
#      depth, or named like the private notes (observations.md, menus-*.txt),
#      ignoring case
#   d) the foreign "diff" URL scheme (Prism uses prism://)
#   e) a Foundation import inside Sources/DiffCore (DiffCore is Foundation-free)
#   f) another product's name outside the files allowed to mention it
#      (the non-affiliation section of CONTRIBUTING.md, docs/compat*) and
#      the lines carrying the non-affiliation notice
#   g) when PRISM_DIRTY_ROOT names the private research workspace: any file
#      whose content is byte-identical to a file under its reference/notes,
#      reference/screens or docs/spec (whatever its path here)
# Scans tracked files plus untracked files that are not ignored.
# Exit status: 0 when clean, 1 otherwise.
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# This script necessarily contains the patterns it looks for.
readonly SELF='scripts/ci/check-cleanroom.sh'

failures=0

fail() {
    echo "check-cleanroom: $1"
    failures=$((failures + 1))
}

# Runs `git grep` over tracked and untracked (non-ignored) text files.
# Prints matches; returns 0 on a match, 1 on no match, exits on git errors.
grep_repo() {
    local status=0
    git grep --untracked -I -n "$@" || status=$?
    if (( status > 1 )); then
        echo "check-cleanroom: git grep failed (status $status)" >&2
        exit 2
    fi
    return "$status"
}

# Lists tracked and untracked (non-ignored) paths that exist in the work tree.
list_paths() {
    git ls-files -co --exclude-standard | while IFS= read -r path; do
        [[ -e "$path" ]] && printf '%s\n' "$path"
    done
}

paths=$(list_paths)

# a) foreign class-name prefixes. Word boundary written portably for ERE.
if grep_repo -E '(^|[^A-Z])(KS|SF)[A-Z]' -- . ":(exclude)$SELF"; then
    fail "identifiers matching (KS|SF)[A-Z] found (see above)"
fi
# ... and in file and directory names (case-sensitive, like the content check)
if named=$(grep -E '(^|[^A-Z])(KS|SF)[A-Z]' <<<"$paths"); then
    printf '%s\n' "$named"
    fail "paths matching (KS|SF)[A-Z] found"
fi

# b) image files anywhere
if images=$(grep -iE '\.(png|jpe?g|gif|tiff?|icns|heic|bmp|webp|psd|ico)$' <<<"$paths" \
        | grep -vE '^docs/screenshots/[A-Za-z0-9._-]+\.png$'); then
    printf '%s\n' "$images"
    fail "image files must not be committed"
fi

# c) private dirty-room paths, at any depth. Case-insensitive: on the
# default macOS file system docs/Spec/ and docs/spec/ are the same directory.
if private=$(grep -iE '(^|/)(reference|docs/spec)/|(^|/)(observations\.md|menus-[^/]*\.txt)$' <<<"$paths"); then
    printf '%s\n' "$private"
    fail "reference/, docs/spec/ or private-notes paths must not be committed"
fi

# d) foreign URL scheme
if grep_repo -F 'diff://' -- . ":(exclude)$SELF"; then
    fail "the diff:// URL scheme must not be used (Prism uses prism://)"
fi

# e) DiffCore must not depend on Foundation
if [[ -d Sources/DiffCore ]]; then
    if grep_repo -E '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?Foundation' \
        -- 'Sources/DiffCore/'; then
        fail "Sources/DiffCore must not import Foundation"
    fi
fi

# f) other products' names. The patterns are assembled so that this file
# does not have to be excluded from the check for containing them.
readonly FOREIGN_NAMES="(Kal""eidoscope|Black[[:space:]]*Pi""xel)"
# The non-affiliation notice (D6: About, Help, README) names the product on
# purpose; a line that carries it is allowed anywhere. README.md may name it
# too: its "Clean-room re-implementation" section explains the project's origin.
readonly NOTICE="not affiliated with Kal""eidoscope[.]"
if named=$(grep_repo -inE "$FOREIGN_NAMES" -- . ":(exclude)CONTRIBUTING.md" ":(exclude)README.md" ":(exclude)docs/compat*") \
    && named=$(grep -vE "$NOTICE" <<<"$named"); then
    printf '%s\n' "$named"
    fail "another product's name appears outside CONTRIBUTING.md, README.md, docs/compat* and the non-affiliation notice"
fi

# g) byte-identical copies of private research files
if [[ -n "${PRISM_DIRTY_ROOT:-}" ]]; then
    if [[ ! -d "$PRISM_DIRTY_ROOT" ]]; then
        fail "PRISM_DIRTY_ROOT=$PRISM_DIRTY_ROOT is not a directory"
    else
        private_hashes=$(
            for dir in reference/notes reference/screens docs/spec; do
                [[ -d "$PRISM_DIRTY_ROOT/$dir" ]] || continue
                find "$PRISM_DIRTY_ROOT/$dir" -type f -size +0 -exec shasum -a 256 {} + | cut -d' ' -f1
            done | sort -u
        )
        if [[ -n "$private_hashes" ]]; then
            while IFS= read -r path; do
                [[ -f "$path" && -s "$path" ]] || continue
                hash=$(shasum -a 256 "$path" | cut -d' ' -f1)
                if grep -Fxq "$hash" <<<"$private_hashes"; then
                    echo "$path"
                    fail "$path is a copy of a private research file"
                fi
            done <<<"$paths"
        fi
    fi
fi

if (( failures > 0 )); then
    echo "check-cleanroom: FAIL ($failures check(s) failed)"
    exit 1
fi
echo "check-cleanroom: OK"
