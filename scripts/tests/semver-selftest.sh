#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Checks that scripts/lib/semver.sh accepts and rejects the same versions as
# PrismInfo.isSemver (keep both lists in sync with PrismInfoTests.swift).
# Exit status: 0 when every case matches, 1 otherwise.
set -uo pipefail

# shellcheck source=../lib/semver.sh
source "$(dirname "$0")/../lib/semver.sh"

valid=(0.1.0 1.2.3 10.20.30 1.0.0-alpha 1.0.0-rc.1+build.5 2.0.0+meta 0.2.0-rc.1)
invalid=("" 1 1.2 1.2.3.4 01.2.3 v1.2.3 1.2.3- "1.2.3 " a.b.c 1.2.3-. 1.2.3+ 1.2.3-a..b)
failures=0
for v in "${valid[@]}"; do
    is_semver "$v" || { echo "not ok: '$v' should be semver"; failures=$((failures + 1)); }
done
for v in "${invalid[@]}"; do
    ! is_semver "$v" || { echo "not ok: '$v' should not be semver"; failures=$((failures + 1)); }
done
(( failures == 0 )) && echo "semver-selftest: OK" || echo "semver-selftest: $failures failure(s)"
(( failures == 0 ))
