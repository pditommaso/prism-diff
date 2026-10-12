// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Testing

@Suite struct UnifiedTests {
    /// `git diff --no-index -U<n>` headers for text/a.swift against
    /// text/b.swift (git 2.x, no configuration), keyed by context size.
    static let gitHeaders: [Int: [String]] = [
        0: ["@@ -1,0 +2 @@", "@@ -3 +4 @@", "@@ -6 +7,2 @@", "@@ -9 +11 @@",
            "@@ -14 +16 @@", "@@ -18 +20 @@", "@@ -20,2 +21,0 @@"],
        1: ["@@ -1,10 +1,12 @@", "@@ -13,3 +15,3 @@", "@@ -17,5 +19,3 @@"],
        2: ["@@ -1,21 +1,21 @@"],
        3: ["@@ -1,21 +1,21 @@"],
    ]

    static func swiftPair() throws -> TextDiffResult {
        TextDiff.diff(try Fixtures.bytes("text/a.swift"), try Fixtures.bytes("text/b.swift"))
    }

    @Test(arguments: [0, 1, 2, 3])
    func swiftPairHeadersMatchGit(context: Int) throws {
        let unified = UnifiedHunks(try Self.swiftPair(), context: context)
        #expect(unified.context == context)
        #expect(unified.hunks.map(\.header) == Self.gitHeaders[context])
    }

    @Test func defaultContextIsThree() throws {
        #expect(UnifiedHunks(try Self.swiftPair()).context == 3)
    }

    @Test func sliderHeaderIsOneLineBelowGit() throws {
        let result = TextDiff.diff(try Fixtures.bytes("text/slider_a.groovy"),
                                   try Fixtures.bytes("text/slider_b.groovy"))
        // git -U3 prints "@@ -7,6 +7,13 @@": it slides the 7-line insert to
        // B lines 10-16. Prism places it at B lines 11-17 (the latest
        // position), so the same-sized hunk starts one line later.
        #expect(UnifiedHunks(result).hunks.map(\.header) == ["@@ -8,6 +8,13 @@"])
    }

    @Test func sequenceShowsEqualOnceThenALinesThenBLines() {
        let result = TextDiff.diff("k\nold1\nold2\nk2\n".bytes, "k\nnew\nk2\n".bytes)
        let lines = result.unifiedLines
        #expect(lines.map(\.kind) == [.context, .removed, .removed, .added, .context])
        #expect(lines.map(\.aLine) == [0, 1, 2, nil, 3])
        #expect(lines.map(\.bLine) == [0, nil, nil, 1, 2])
        for line in lines {
            let block = result.blocks[line.blockIndex]
            if let a = line.aLine { #expect(block.a.contains(a)) }
            if let b = line.bLine { #expect(block.b.contains(b)) }
        }
    }

    @Test func lineCountInvariantsHold() throws {
        let result = try Self.swiftPair()
        let lines = result.unifiedLines
        // Every A line and every B line appears exactly once, in order.
        #expect(lines.compactMap(\.aLine) == Array(0 ..< result.linesA.count))
        #expect(lines.compactMap(\.bLine) == Array(0 ..< result.linesB.count))
        for context in 0 ... 4 {
            let unified = UnifiedHunks(result, context: context)
            var previousEnd = 0
            for hunk in unified.hunks {
                let slice = unified.lines[hunk.lines]
                #expect(hunk.aCount == slice.filter { $0.aLine != nil }.count)
                #expect(hunk.bCount == slice.filter { $0.bLine != nil }.count)
                #expect(slice.first?.kind != .context || context > 0)
                // Hunks are ordered and disjoint, and none starts or ends
                // with more than `context` context lines.
                #expect(hunk.lines.lowerBound >= previousEnd)
                previousEnd = hunk.lines.upperBound
                let leading = slice.prefix { $0.kind == .context }.count
                let trailing = slice.reversed().prefix { $0.kind == .context }.count
                #expect(leading <= context && trailing <= context)
            }
            // Every difference is inside some hunk.
            let covered = Set(unified.hunks.flatMap { Array($0.lines) })
            for (i, line) in lines.enumerated() where line.kind != .context {
                #expect(covered.contains(i))
            }
        }
    }

    @Test func emptySidesUseTheZeroStartConvention() {
        let added = UnifiedHunks(TextDiff.diff([], "a\nb\nc\n".bytes))
        #expect(added.hunks.map(\.header) == ["@@ -0,0 +1,3 @@"])
        let removed = UnifiedHunks(TextDiff.diff("a\n".bytes, []))
        #expect(removed.hunks.map(\.header) == ["@@ -1 +0,0 @@"])
    }

    @Test func identicalInputsHaveNoHunks() {
        let text = "same\nlines\n".bytes
        #expect(UnifiedHunks(TextDiff.diff(text, text)).hunks.isEmpty)
        #expect(UnifiedHunks(TextDiff.diff([], [])).hunks.isEmpty)
    }

    @Test func distantChangesSplitIntoSeparateHunks() {
        let a = (0 ..< 20).map { "line \($0)\n" }.joined()
        var bLines = (0 ..< 20).map { "line \($0)\n" }
        bLines[2] = "changed 2\n"
        bLines[17] = "changed 17\n"
        let result = TextDiff.diff(a.bytes, bLines.joined().bytes)
        #expect(UnifiedHunks(result).hunks.map(\.header) == ["@@ -1,6 +1,6 @@", "@@ -15,6 +15,6 @@"])
        // Exactly 2 * context equal lines between changes still merge.
        bLines[17] = "line 17\n"
        bLines[9] = "changed 9\n"
        let merged = TextDiff.diff(a.bytes, bLines.joined().bytes)
        #expect(UnifiedHunks(merged).hunks.map(\.header) == ["@@ -1,13 +1,13 @@"])
    }
}
