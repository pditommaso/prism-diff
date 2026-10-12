// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// Line-hunk counting for the cross-check against `git diff -U0`.
///
/// A line hunk is a maximal run of adjacent non-equal blocks. That is what
/// git prints as one `@@` header at zero context: a change block directly
/// followed by an insert, for example, is a single hunk for git.
public enum LineHunks {
    /// The number of maximal runs of adjacent non-equal blocks in `result`.
    public static func count(_ result: TextDiffResult) -> Int {
        var hunks = 0
        var inHunk = false
        for block in result.blocks {
            let different = block.kind != .equal
            if different && !inHunk { hunks += 1 }
            inHunk = different
        }
        return hunks
    }

    /// The number of hunk headers (lines starting with "@@ ") in a unified
    /// diff, as printed by `git diff`.
    public static func headerCount(inUnifiedDiff text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .count { $0.hasPrefix("@@ ") }
    }
}
