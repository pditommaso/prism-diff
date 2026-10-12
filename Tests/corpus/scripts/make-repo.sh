#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Builds the git fixture repository used by the Git integration tests.
# A nested .git cannot be committed, so the history is replayed from the
# per-step file snapshots in Tests/corpus/fixtures/repo-src/:
#
#   1-init      commit "init" on master   (conf.ini, main.swift, notes.txt)
#   2-mainchg   commit "mainchg" on master (notes.txt)
#   3-feat      commit "feat" on branch feature, forked from "init" (notes.txt)
#   4-worktree  uncommitted edits on master (conf.ini, main.swift)
#
# The result has master checked out, 3 commits in total and 2 modified files.
# Author, committer and dates are fixed, so commit hashes are reproducible:
#   init 3a9becc, mainchg fefde12, feat 5dff3f6
#
# The user's git configuration is never read or written: global and system
# config are disabled for every git command run here.
#
# Usage: make-repo.sh DEST   (DEST must not exist or must be an empty directory)
set -euo pipefail

usage() {
    echo "usage: $(basename "$0") DEST" >&2
    exit 2
}

[[ $# -eq 1 && -n "$1" ]] || usage
dest="$1"

src="$(cd "$(dirname "$0")/../fixtures/repo-src" && pwd)"

if [[ -e "$dest" ]]; then
    if [[ ! -d "$dest" || -n "$(ls -A "$dest")" ]]; then
        echo "make-repo: $dest exists and is not an empty directory" >&2
        exit 1
    fi
fi
mkdir -p "$dest"

# Isolate from any user or system git configuration and hooks.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_TEMPLATE_DIR
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

g() {
    git -C "$dest" -c core.hooksPath=/dev/null -c commit.gpgSign=false \
        -c core.autocrlf=false "$@"
}

# Copies the files of one snapshot step into the work tree.
apply_step() {
    cp -p "$src/$1"/* "$dest/"
}

# Commits everything in the work tree with a fixed timestamp.
commit_at() {
    local message="$1" stamp="$2"
    g add -A
    GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
        g commit --quiet --no-verify -m "$message"
}

g init --quiet --initial-branch=master --template=

apply_step 1-init
commit_at init "1791722789 +0200"

apply_step 2-mainchg
commit_at mainchg "1791722790 +0200"

g checkout --quiet -b feature HEAD~1
apply_step 3-feat
commit_at feat "1791722790 +0200"

g checkout --quiet master
apply_step 4-worktree

echo "make-repo: created $dest"
