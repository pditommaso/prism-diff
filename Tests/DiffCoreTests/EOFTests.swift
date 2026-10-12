// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Testing

@Suite struct EOFTests {
    static let withNewline = "alpha\nbeta\ngamma\n".bytes
    static let withoutNewline = "alpha\nbeta\ngamma".bytes

    @Test func finalNewlineFlagsReflectTheInputs() {
        let result = TextDiff.diff(Self.withNewline, Self.withoutNewline)
        #expect(result.aHasFinalNewline)
        #expect(!result.bHasFinalNewline)
        #expect(!TextDiff.diff([], []).aHasFinalNewline)
        #expect(TextDiff.diff("x\r\n".bytes, "x\r".bytes).bHasFinalNewline)
    }

    @Test(arguments: [false, true])
    func finalNewlineOnlyDifferenceIsAChangeOfTheLastLineAtWs0(swapped: Bool) {
        let (a, b) = swapped ? (Self.withoutNewline, Self.withNewline) : (Self.withNewline, Self.withoutNewline)
        let result = TextDiff.diff(a, b)
        #expect(result.changeCount == 1)
        #expect(result.blocks == [
            DiffBlock(kind: .equal, a: 0 ..< 2, b: 0 ..< 2),
            DiffBlock(kind: .change, a: 2 ..< 3, b: 2 ..< 3, words: [
                swapped ? WordHunk(aLine: 2, bLine: 2, a: 5 ..< 5, b: 5 ..< 6)
                        : WordHunk(aLine: 2, bLine: 2, a: 5 ..< 6, b: 5 ..< 5),
            ]),
        ])
        #expect(result.blocks[1].isChange)
        #expect(result.blocks[1].words[0].kind == (swapped ? .insertOnly : .deleteOnly))
        #expect(UnifiedHunks(result).hunks.map(\.header) == ["@@ -1,3 +1,3 @@"])
    }

    /// spec: end-of-file markers are applied after the comparison, so a
    /// difference only in the final newline shows at every mode.
    @Test(arguments: [WhitespaceMode.ignoreLineEndings, .ignoreEdgeWhitespace])
    func finalNewlineOnlyDifferenceIsAChangeAtWs1AndWs2(mode: WhitespaceMode) {
        for swapped in [false, true] {
            let (a, b) = swapped ? (Self.withoutNewline, Self.withNewline) : (Self.withNewline, Self.withoutNewline)
            let result = TextDiff.diff(a, b, options: DiffOptions(whitespace: mode))
            #expect(!result.isIdentical)
            #expect(result.blocks == [
                DiffBlock(kind: .equal, a: 0 ..< 2, b: 0 ..< 2),
                DiffBlock(kind: .change, a: 2 ..< 3, b: 2 ..< 3, words: [
                    swapped ? WordHunk(aLine: 2, bLine: 2, a: 5 ..< 5, b: 5 ..< 6)
                            : WordHunk(aLine: 2, bLine: 2, a: 5 ..< 6, b: 5 ..< 5),
                ]),
            ])
            #expect(result.aHasFinalNewline != result.bHasFinalNewline)
        }
        // CRLF on one side and nothing on the other: the hunk is the CRLF.
        let result = TextDiff.diff("one\r\ntwo\r\n".bytes, "one\r\ntwo".bytes, options: DiffOptions(whitespace: mode))
        #expect(result.blocks == [
            DiffBlock(kind: .equal, a: 0 ..< 1, b: 0 ..< 1),
            DiffBlock(kind: .change, a: 1 ..< 2, b: 1 ..< 2,
                      words: [WordHunk(aLine: 1, bLine: 1, a: 3 ..< 5, b: 3 ..< 3)]),
        ])
        // A single line, and line endings that differ only in style.
        #expect(TextDiff.diff("x".bytes, "x\n".bytes, options: DiffOptions(whitespace: mode)).changeCount == 1)
        #expect(TextDiff.diff("x\r\n".bytes, "x\n".bytes, options: DiffOptions(whitespace: mode)).isIdentical)
        #expect(TextDiff.diff("x\ry\r".bytes, "x\ny\n".bytes, options: DiffOptions(whitespace: mode)).isIdentical)
    }

    @Test func eofChangeMergesWithAChangeJustBeforeIt() {
        // Line 2 changed and the final newline dropped: one change block.
        let result = TextDiff.diff("a\nb c\nd\n".bytes, "a\nb x\nd".bytes,
                                   options: DiffOptions(whitespace: .ignoreLineEndings))
        #expect(result.blocks.count == 2)
        #expect(result.blocks[1].kind == .change)
        #expect(result.blocks[1].a == 1 ..< 3 && result.blocks[1].b == 1 ..< 3)
        #expect(result.blocks[1].words.last == WordHunk(aLine: 2, bLine: 2, a: 1 ..< 2, b: 1 ..< 1))
    }

    @Test func eofChangeInWs2KeepsTrailingBlanksIgnored() {
        let result = TextDiff.diff("a\nb  \n".bytes, "a\nb".bytes, options: DiffOptions(whitespace: .ignoreEdgeWhitespace))
        #expect(result.blocks.last == DiffBlock(kind: .change, a: 1 ..< 2, b: 1 ..< 2,
                                                words: [WordHunk(aLine: 1, bLine: 1, a: 3 ..< 4, b: 1 ..< 1)]))
    }

    @Test func singleLineWithoutNewlineAgainstWithNewline() {
        let result = TextDiff.diff("x".bytes, "x\n".bytes)
        #expect(result.blocks == [DiffBlock(kind: .change, a: 0 ..< 1, b: 0 ..< 1,
                                            words: [WordHunk(aLine: 0, bLine: 0, a: 1 ..< 1, b: 1 ..< 2)])])
    }
}
