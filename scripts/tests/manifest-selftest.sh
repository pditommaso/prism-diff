#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Checks the toolchain-dependent flags that Package.swift computes:
#   - every "-plugin-path" it passes points inside the toolchain that runs
#     `swift` here (never a second toolchain installed next to it, such as
#     the Command Line Tools on a machine that builds with Xcode);
#   - when the active toolchain has usr/lib/swift/host/plugins/testing (the
#     Command Line Tools layout), the flag is present, so `swift test` works.
# Exit status: 0 when both hold, 1 otherwise.
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

swift_bin=$(xcrun --find swift)
toolchain=${swift_bin%/usr/bin/swift}
[[ "$toolchain" != "$swift_bin" ]] || { echo "not ok: unexpected swift path $swift_bin"; exit 1; }
echo "active toolchain: $toolchain"

dump=$(swift package dump-package)
# Each plugin path follows its "-plugin-path" entry in the unsafeFlags arrays.
paths=$(/usr/bin/python3 -I -c '
import json, sys
def walk(node):
    if isinstance(node, dict):
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            if value == "-plugin-path" and i + 1 < len(node):
                print(node[i + 1])
            yield from walk(value)
list(walk(json.load(sys.stdin)))
' <<<"$dump" | sort -u)

failures=0
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ "$path" == "$toolchain/"* ]]; then
        echo "ok: plugin path $path belongs to the active toolchain"
    else
        echo "not ok: plugin path $path is outside the active toolchain"
        failures=$((failures + 1))
    fi
done <<<"$paths"

if [[ -d "$toolchain/usr/lib/swift/host/plugins/testing" ]]; then
    if grep -Fxq "$toolchain/usr/lib/swift/host/plugins/testing" <<<"$paths"; then
        echo "ok: testing plugin path passed for this toolchain"
    else
        echo "not ok: toolchain has a testing plugin directory but no flag names it"
        failures=$((failures + 1))
    fi
fi

(( failures == 0 )) && echo "manifest-selftest: OK" || echo "manifest-selftest: $failures failure(s)"
(( failures == 0 ))
