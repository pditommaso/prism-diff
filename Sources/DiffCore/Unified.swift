// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

// Unified representation of a two-way diff: one interleaved sequence where
// equal lines appear once and every difference shows its A lines followed by
// its B lines, plus the grouping of that sequence into `diff -u` hunks.

/// The role of a line in the unified sequence.
public enum UnifiedLineKind: String, Sendable, CaseIterable {
    /// Equal on both sides; shown once.
    case context
    /// Only in A.
    case removed
    /// Only in B.
    case added
}

/// One line of the unified sequence. Line numbers are 0-based indices into
/// A and B; a context line has both, a removed line only `aLine`, an added
/// line only `bLine`. `blockIndex` is the index of the block in
/// `TextDiffResult.blocks` the line comes from.
public struct UnifiedLine: Sendable, Equatable, Hashable {
    public var kind: UnifiedLineKind
    public var aLine: Int?
    public var bLine: Int?
    public var blockIndex: Int

    public init(kind: UnifiedLineKind, aLine: Int?, bLine: Int?, blockIndex: Int) {
        self.kind = kind
        self.aLine = aLine
        self.bLine = bLine
        self.blockIndex = blockIndex
    }
}

extension TextDiffResult {
    /// The unified sequence: equal blocks contribute their lines once, every
    /// other block its A lines followed by its B lines.
    public var unifiedLines: [UnifiedLine] {
        var out: [UnifiedLine] = []
        out.reserveCapacity(max(linesA.count, linesB.count))
        for (index, block) in blocks.enumerated() {
            if block.kind == .equal {
                for k in 0 ..< block.a.count {
                    out.append(UnifiedLine(kind: .context, aLine: block.a.lowerBound + k,
                                           bLine: block.b.lowerBound + k, blockIndex: index))
                }
            } else {
                for line in block.a {
                    out.append(UnifiedLine(kind: .removed, aLine: line, bLine: nil, blockIndex: index))
                }
                for line in block.b {
                    out.append(UnifiedLine(kind: .added, aLine: nil, bLine: line, blockIndex: index))
                }
            }
        }
        return out
    }
}

/// One `@@ -aStart,aCount +bStart,bCount @@` hunk.
public struct UnifiedHunk: Sendable, Equatable, Hashable {
    /// As printed in the header: the 1-based first A line, or, when
    /// `aCount` is 0, the number of the A line after which the change sits
    /// (0 at the top of the file). This is the `diff -u` convention.
    public var aStart: Int
    /// A lines in the hunk (context plus removed).
    public var aCount: Int
    /// Like `aStart`, for B.
    public var bStart: Int
    /// B lines in the hunk (context plus added).
    public var bCount: Int
    /// The hunk's lines, as a range of the unified sequence.
    public var lines: Range<Int>

    public init(aStart: Int, aCount: Int, bStart: Int, bCount: Int, lines: Range<Int>) {
        self.aStart = aStart
        self.aCount = aCount
        self.bStart = bStart
        self.bCount = bCount
        self.lines = lines
    }

    /// The header line, without a trailing newline. A count of 1 is
    /// omitted, as `diff -u` and git do.
    public var header: String {
        func side(_ start: Int, _ count: Int) -> String {
            count == 1 ? "\(start)" : "\(start),\(count)"
        }
        return "@@ -\(side(aStart, aCount)) +\(side(bStart, bCount)) @@"
    }
}

/// The unified sequence grouped into hunks with `context` lines of context
/// around each difference. Differences separated by at most `2 * context`
/// equal lines share a hunk, so the counts equal those of `diff -u`.
public struct UnifiedHunks: Sendable, Equatable {
    public let context: Int
    /// The unified sequence, except that within each run of differences all
    /// removed lines come before all added lines, as in `diff -u`; hunks
    /// index into it.
    public let lines: [UnifiedLine]
    public let hunks: [UnifiedHunk]

    public init(_ result: TextDiffResult, context: Int = 3) {
        precondition(context >= 0, "context must not be negative")
        self.context = context
        // diff -u lists every removed line of a run of differences before
        // its added lines; patch(1) expects that order (a "\\ No newline"
        // marker after a removed line must end the removed part). The
        // unified sequence interleaves per block, so reorder each run.
        // Built in one linear pass: replacing each run in place would copy
        // the whole array once per run.
        let unified = result.unifiedLines
        var lines: [UnifiedLine] = []
        lines.reserveCapacity(unified.count)
        var start = 0
        while start < unified.count {
            guard unified[start].kind != .context else {
                lines.append(unified[start])
                start += 1
                continue
            }
            var end = start + 1
            while end < unified.count && unified[end].kind != .context { end += 1 }
            for line in unified[start ..< end] where line.kind == .removed { lines.append(line) }
            for line in unified[start ..< end] where line.kind == .added { lines.append(line) }
            start = end
        }
        self.lines = lines

        // A and B lines before each position of the sequence.
        var aBefore = [Int](repeating: 0, count: lines.count + 1)
        var bBefore = [Int](repeating: 0, count: lines.count + 1)
        for (i, line) in lines.enumerated() {
            aBefore[i + 1] = aBefore[i] + (line.aLine == nil ? 0 : 1)
            bBefore[i + 1] = bBefore[i] + (line.bLine == nil ? 0 : 1)
        }

        // Maximal runs of non-context lines.
        var runs: [Range<Int>] = []
        var i = 0
        while i < lines.count {
            if lines[i].kind == .context {
                i += 1
                continue
            }
            var j = i + 1
            while j < lines.count && lines[j].kind != .context { j += 1 }
            runs.append(i ..< j)
            i = j
        }

        var hunks: [UnifiedHunk] = []
        var r = 0
        while r < runs.count {
            var last = runs[r]
            var s = r + 1
            while s < runs.count && runs[s].lowerBound - last.upperBound <= 2 * context {
                last = runs[s]
                s += 1
            }
            let lower = max(0, runs[r].lowerBound - context)
            let upper = min(lines.count, last.upperBound + context)
            let aCount = aBefore[upper] - aBefore[lower]
            let bCount = bBefore[upper] - bBefore[lower]
            hunks.append(UnifiedHunk(aStart: aBefore[lower] + (aCount > 0 ? 1 : 0), aCount: aCount,
                                     bStart: bBefore[lower] + (bCount > 0 ? 1 : 0), bCount: bCount,
                                     lines: lower ..< upper))
            r = s
        }
        self.hunks = hunks
    }
}
