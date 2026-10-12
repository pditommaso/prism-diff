// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
import DiffCore
import Testing

@Suite struct WhitespaceModeTests {
    static func sample(_ count: Int) -> [String] {
        var rng = SplitMix64(seed: 7)
        return CaseGenerator.randomLines(count, &rng)
    }

    @Test func crlfAgainstLFHasNoDifferencesAtWs1() {
        let lines = Self.sample(500)
        let lf = CaseGenerator.join(lines, eol: "\n", finalNewline: true)
        let crlf = CaseGenerator.join(lines, eol: "\r\n", finalNewline: true)
        let result = TextDiff.diff(lf, crlf, options: DiffOptions(whitespace: .ignoreLineEndings))
        #expect(result.changeCount == 0)
        #expect(result.blocks == [DiffBlock(kind: .equal, a: 0 ..< 500, b: 0 ..< 500)])
    }

    @Test func crlfAgainstLFHighlightsTerminatorsAtWs0() {
        let a = "one\ntwo\nthree\n".bytes, b = "one\r\ntwo\r\nthree\r\n".bytes
        let result = TextDiff.diff(a, b)
        #expect(result.blocks.count == 1)
        let block = result.blocks[0]
        #expect(block.kind == .change && block.a == 0 ..< 3 && block.b == 0 ..< 3)
        #expect(block.words == [
            WordHunk(aLine: 0, bLine: 0, a: 3 ..< 4, b: 3 ..< 5),
            WordHunk(aLine: 1, bLine: 1, a: 3 ..< 4, b: 3 ..< 5),
            WordHunk(aLine: 2, bLine: 2, a: 5 ..< 6, b: 5 ..< 7),
        ])
    }

    @Test func reindentAndTrailingBlanksHaveNoDifferencesAtWs2() {
        let lines = Self.sample(500)
        let a = CaseGenerator.join(lines, eol: "\n", finalNewline: true)
        let b = CaseGenerator.join(lines.map { "\t  " + $0 + " \t" }, eol: "\n", finalNewline: true)
        #expect(TextDiff.diff(a, b, options: DiffOptions(whitespace: .ignoreEdgeWhitespace)).changeCount == 0)
        #expect(TextDiff.diff(a, b, options: DiffOptions(whitespace: .ignoreLineEndings)).changeCount > 0)
    }

    @Test func ws2DoesNotHighlightEdgeBlanks() {
        let a = "    value = 1\n".bytes, b = "\tvalue = 2   \n".bytes
        let result = TextDiff.diff(a, b, options: DiffOptions(whitespace: .ignoreEdgeWhitespace))
        #expect(result.blocks == [DiffBlock(kind: .change, a: 0 ..< 1, b: 0 ..< 1,
                                            words: [WordHunk(aLine: 0, bLine: 0, a: 12 ..< 13, b: 9 ..< 10)])])
    }

    @Test func missingFinalNewlineIsADifferenceAtEveryMode() {
        let a = "one\ntwo\n".bytes, b = "one\ntwo".bytes
        for mode in WhitespaceMode.allCases {
            #expect(TextDiff.diff(a, b, options: DiffOptions(whitespace: mode)).changeCount == 1)
        }
    }
}
