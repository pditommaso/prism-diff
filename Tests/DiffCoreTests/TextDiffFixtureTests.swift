// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
import DiffCore
import Testing

@Suite struct TextDiffFixtureTests {
    /// The expected result for text/a.swift against text/b.swift. Block 7 is
    /// Prism's own value: b.swift says "Prism" on that line (see
    /// Tests/corpus/README.md, "Deliberate differences").
    static let expected: [DiffBlock] = [
        DiffBlock(kind: .insert, a: 1 ..< 1, b: 1 ..< 2),
        DiffBlock(kind: .change, a: 2 ..< 3, b: 3 ..< 4,
                  words: [WordHunk(aLine: 2, bLine: 3, a: 13 ..< 13, b: 13 ..< 24)]),
        DiffBlock(kind: .change, a: 5 ..< 6, b: 6 ..< 7,
                  words: [WordHunk(aLine: 5, bLine: 6, a: 24 ..< 29, b: 24 ..< 28)]),
        DiffBlock(kind: .insert, a: 6 ..< 6, b: 7 ..< 8),
        DiffBlock(kind: .change, a: 8 ..< 9, b: 10 ..< 11,
                  words: [WordHunk(aLine: 8, bLine: 10, a: 19 ..< 19, b: 19 ..< 56)]),
        DiffBlock(kind: .change, a: 13 ..< 14, b: 15 ..< 16,
                  words: [WordHunk(aLine: 13, bLine: 15, a: 0 ..< 8, b: 0 ..< 12)]),
        DiffBlock(kind: .change, a: 17 ..< 18, b: 19 ..< 20,
                  words: [WordHunk(aLine: 17, bLine: 19, a: 23 ..< 28, b: 23 ..< 28)]),
        DiffBlock(kind: .delete, a: 19 ..< 21, b: 21 ..< 21),
    ]

    @Test func swiftPairHasEightReferenceChanges() throws {
        let a = try Fixtures.bytes("text/a.swift"), b = try Fixtures.bytes("text/b.swift")
        let result = TextDiff.diff(a, b)
        #expect(result.changeCount == 8)
        #expect(Fixtures.differences(result) == Self.expected)
        #expect(InvariantChecker.violations(of: result, a, b, whitespace: .exact).isEmpty)
    }

    @Test func swiftPairWordRangesSelectTheChangedText() throws {
        let a = try Fixtures.bytes("text/a.swift"), b = try Fixtures.bytes("text/b.swift")
        let result = TextDiff.diff(a, b)
        func text(_ buffer: [UInt8], _ lines: LineIndex, _ line: Int, _ columns: Range<Int>) -> String {
            let start = lines.range(line).lowerBound
            return String(decoding: buffer[start + columns.lowerBound ..< start + columns.upperBound], as: UTF8.self)
        }
        let words = Fixtures.differences(result).flatMap(\.words)
        let changed = words.map { (text(a, result.linesA, $0.aLine, $0.a), text(b, result.linesB, $0.bLine, $0.b)) }
        #expect(changed.map(\.0) == ["", "false", "", "        ", "World"])
        #expect(changed.map(\.1) == ["a friendly ", "true", #"language == "it" ? "Ciao, \(name)" : "#,
                                     "            ", "Prism"])
    }

    @Test(arguments: [false, true])
    func swiftPairIsTheSameSerialAndParallel(parallel: Bool) throws {
        let a = try Fixtures.bytes("text/a.swift"), b = try Fixtures.bytes("text/b.swift")
        let result = TextDiff.diff(a, b, options: DiffOptions(parallel: parallel))
        #expect(Fixtures.differences(result) == Self.expected)
    }

    @Test func sliderInsertIsPlacedAtLinesElevenToSeventeen() throws {
        let a = try Fixtures.bytes("text/slider_a.groovy"), b = try Fixtures.bytes("text/slider_b.groovy")
        let result = TextDiff.diff(a, b)
        // 0-based half-open 10..<17 is 1-based B lines 11-17.
        #expect(Fixtures.differences(result) == [DiffBlock(kind: .insert, a: 10 ..< 10, b: 10 ..< 17)])
        #expect(result.blocks == [
            DiffBlock(kind: .equal, a: 0 ..< 10, b: 0 ..< 10),
            DiffBlock(kind: .insert, a: 10 ..< 10, b: 10 ..< 17),
            DiffBlock(kind: .equal, a: 10 ..< 17, b: 17 ..< 24),
        ])
    }

    @Test func bigFixtureIsAValidScript() throws {
        let a = try Fixtures.bytes("text/big_a.txt"), b = try Fixtures.bytes("text/big_b.txt")
        let result = TextDiff.diff(a, b)
        #expect(result.linesA.count == 100_000)
        #expect(result.linesB.count == 100_099)
        #expect(result.changeCount > 0)
        #expect(InvariantChecker.violations(of: result, a, b, whitespace: .exact).isEmpty)
    }
}
