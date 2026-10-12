# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# SemVer 2.0 check shared by bundle.sh and the acceptance scripts. Uses the
# same grammar as PrismInfo.isSemver: MAJOR.MINOR.PATCH without leading
# zeros, then optional -prerelease and +build dot-separated identifiers.
# Source this file; do not execute it.

# is_semver <text>: exit status 0 when <text> is a SemVer 2.0 version.
is_semver() {
    local num='(0|[1-9][0-9]*)' id='[0-9A-Za-z-]+'
    local re="^$num\\.$num\\.$num(-$id(\\.$id)*)?(\\+$id(\\.$id)*)?\$"
    [[ "$1" =~ $re ]]
}
