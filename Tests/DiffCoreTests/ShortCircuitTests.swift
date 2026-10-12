// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Testing

@Suite struct ShortCircuitTests {
    @Test func bothEmptyHasNoBlocks() {
        let result = TextDiff.diff([], [])
        #expect(result.blocks.isEmpty)
        #expect(result.linesA.count == 0 && result.linesB.count == 0)
        #expect(result.isIdentical)
    }

    @Test func emptyAIsOneInsert() {
        let result = TextDiff.diff([], "one\ntwo\nthree".bytes)
        #expect(result.blocks == [DiffBlock(kind: .insert, a: 0 ..< 0, b: 0 ..< 3)])
        #expect(result.changeCount == 1)
    }

    @Test func emptyBIsOneDelete() {
        let result = TextDiff.diff("one\ntwo\n".bytes, [])
        #expect(result.blocks == [DiffBlock(kind: .delete, a: 0 ..< 2, b: 0 ..< 0)])
    }

    @Test(arguments: WhitespaceMode.allCases)
    func identicalBytesAreOneEqualBlock(mode: WhitespaceMode) {
        let text = "alpha\r\nbeta\n\tgamma".bytes
        let result = TextDiff.diff(text, text, options: DiffOptions(whitespace: mode))
        #expect(result.blocks == [DiffBlock(kind: .equal, a: 0 ..< 3, b: 0 ..< 3)])
        #expect(result.isIdentical)
    }

    @Test func lineIndexKeepsTerminatorsWithTheirLine() {
        let result = TextDiff.diff("a\r\nb\rc\nd".bytes, "x".bytes)
        #expect(result.linesA.starts == [0, 3, 5, 7, 8])
        #expect(result.linesA.range(1) == 3 ..< 5)
        #expect(result.linesB.count == 1)
    }

    @Test func singleLineChangeHasWordHunk() {
        let result = TextDiff.diff("let x = 1\n".bytes, "let y = 1\n".bytes)
        #expect(result.blocks == [DiffBlock(kind: .change, a: 0 ..< 1, b: 0 ..< 1,
                                            words: [WordHunk(aLine: 0, bLine: 0, a: 4 ..< 5, b: 4 ..< 5)])])
    }

    @Test func defaultOptionsAreTheProductionSettings() {
        let options = DiffOptions()
        #expect(options.whitespace == .exact)
        #expect(options.parallel)
        #expect(options.maxRefineTokens == 500_000)
        #expect(options.myersMinCost == 256)
        #expect(options.prePairBytes == 64 * 1024)
    }

    @Test func refinementValveSplitsBigBlocks() {
        let a = "alpha beta gamma\ndelta epsilon\n".bytes, b = "alpha beta zeta\ndelta eta\n".bytes
        let result = TextDiff.diff(a, b, options: DiffOptions(maxRefineTokens: 4))
        #expect(result.blocks == [DiffBlock(kind: .delete, a: 0 ..< 2, b: 0 ..< 0),
                                  DiffBlock(kind: .insert, a: 2 ..< 2, b: 0 ..< 2)])
    }
}
