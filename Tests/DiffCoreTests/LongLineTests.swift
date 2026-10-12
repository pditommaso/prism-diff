// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

@testable import DiffCore
import DiffCheck
import Testing

/// Long lines: the tokenizer's in-line cancellation and limit checks, the
/// line-pair token limit, and the folding of a line pair's common prefix and
/// suffix.
@Suite struct LongLineTests {
    /// One line of `count` punctuation bytes: one token per byte.
    static func punctuationLine(_ count: Int) -> [UInt8] {
        Array(repeating: UInt8(ascii: ","), count: count) + [10]
    }

    @Test func tokenizingOneLineStopsAtTheFirstCheckPointWhenCancelled() {
        let line = Self.punctuationLine(300_000)
        let flag = CancellationFlag()
        flag.cancel()
        var tokens = Tokens()
        let finished = line.withUnsafeBufferPointer { p in
            tokens.tokenizeLine(p.baseAddress!, 0, p.count, line: 0, ws: 0, interner: Interner(expected: 16),
                                cancellation: flag)
        }
        #expect(!finished)
        #expect(tokens.count == Tokens.checkInterval)
    }

    @Test func tokenizingOneLineStopsAtTheFirstCheckPointPastTheLimit() {
        let line = Self.punctuationLine(300_000)
        var tokens = Tokens()
        let finished = line.withUnsafeBufferPointer { p in
            tokens.tokenizeLine(p.baseAddress!, 0, p.count, line: 0, ws: 0, interner: Interner(expected: 16),
                                limit: 1000)
        }
        #expect(!finished)
        #expect(tokens.count == Tokens.checkInterval)
    }

    @Test func tokenizingWithoutCancellationOrLimitCoversTheWholeLine() {
        let line = Self.punctuationLine(300_000)
        var tokens = Tokens()
        let finished = line.withUnsafeBufferPointer { p in
            tokens.tokenizeLine(p.baseAddress!, 0, p.count, line: 0, ws: 0, interner: Interner(expected: 16))
        }
        #expect(finished)
        #expect(tokens.count == 300_001)
    }

    /// One long line of `count` JSON fields with the fields in `edited`
    /// changed.
    static func jsonLine(fields count: Int, edited: Set<Int>) -> [UInt8] {
        var text = ""
        for i in 0 ..< count {
            text += edited.contains(i) ? "{\"k\(i)\":\"changed\"}," : "{\"k\(i)\":\"value\"},"
        }
        return Array((text + "\n").utf8)
    }

    @Test func aLinePairOverItsTokenLimitIsADeleteAndAnInsert() {
        // About 50,000 tokens per side between the first and the last edit,
        // against a pair limit of 16 x 100.
        let a = Self.jsonLine(fields: 5000, edited: [])
        let b = Self.jsonLine(fields: 5000, edited: [10, 4990])
        let result = TextDiff.diff(a, b, options: DiffOptions(maxRefineTokens: 100))
        #expect(result.blocks.map(\.kind) == [.delete, .insert])
    }

    @Test func aLocalEditInALineFarOverTheLimitIsStillRefined() {
        // The common prefix and suffix are folded away, so only the edited
        // field counts against the limit.
        let a = Self.jsonLine(fields: 5000, edited: [])
        let b = Self.jsonLine(fields: 5000, edited: [2500])
        let result = TextDiff.diff(a, b, options: DiffOptions(maxRefineTokens: 10))
        #expect(result.blocks.map(\.kind) == [.change])
        let prefix = Array("{\"k2500\":\"".utf8)
        let column = a.indices.first { a[$0...].starts(with: prefix) }! + prefix.count
        #expect(result.blocks.first?.words.map(\.a) == [column ..< column + 5])
        #expect(result.blocks.first?.words.map(\.b) == [column ..< column + 7])
    }

    @Test func aWhitespaceEqualPairOverItsLimitIsMarkedChangedAsAWhole() {
        // Pre-pairing pairs line 0 with line 0 (equal ignoring the outer
        // blanks); with nothing in common at either end it cannot be folded
        // and is over the pair limit, so the whole content is one hunk.
        let body = String(repeating: "w ", count: 3000) + "end"
        let a = Array(("  " + body + "  \nzzz\n").utf8)
        let b = Array((body + "\nyyy\n").utf8)
        let result = TextDiff.diff(a, b, options: DiffOptions(maxRefineTokens: 10, prePairBytes: 1))
        #expect(result.blocks.map(\.kind) == [.change])
        let words = result.blocks.first?.words ?? []
        #expect(words.first == WordHunk(aLine: 0, bLine: 0, a: 0 ..< body.utf8.count + 4, b: 0 ..< body.utf8.count))
        #expect(words.count == 2)
    }

    // MARK: folding equivalence

    /// Word hunks of one line pair with every token spelled out: the
    /// unfolded reference for `Refiner.pairDiff`.
    static func referenceHunks(_ a: [UInt8], _ b: [UInt8], ws: Int) -> [WordHunk]? {
        let interner = Interner(expected: 64)
        var x = Tokens(), y = Tokens()
        a.withUnsafeBufferPointer { p in
            _ = x.tokenizeLine(p.baseAddress!, 0, p.count, line: 0, ws: ws, interner: interner)
        }
        b.withUnsafeBufferPointer { p in
            _ = y.tokenizeLine(p.baseAddress!, 0, p.count, line: 0, ws: ws, interner: interner)
        }
        let myers = Myers(minCost: 256, scaled: false)
        x.ids.withUnsafeBufferPointer { ia in
            y.ids.withUnsafeBufferPointer { ib in
                if let pa = ia.baseAddress, let pb = ib.baseAddress { myers.diff(pa, 0, ia.count, pb, 0, ib.count) }
            }
        }
        if myers.matchesA.isEmpty { return nil }
        func columns(_ t: Tokens, _ previous: Int, _ next: Int) -> Range<Int> {
            if next > previous + 1 { return t.start(previous + 1) ..< t.end(next - 1) }
            let point = previous >= 0 ? t.end(previous) : (next < t.count ? t.start(next) : 0)
            return point ..< point
        }
        var out: [WordHunk] = []
        var previousA = -1, previousB = -1
        for k in 0 ... myers.matchesA.count {
            let nextA = k < myers.matchesA.count ? Int(myers.matchesA[k]) : x.count
            let nextB = k < myers.matchesB.count ? Int(myers.matchesB[k]) : y.count
            if nextA > previousA + 1 || nextB > previousB + 1 {
                out.append(WordHunk(aLine: 0, bLine: 0, a: columns(x, previousA, nextA),
                                    b: columns(y, previousB, nextB)))
            }
            previousA = nextA
            previousB = nextB
        }
        return out
    }

    static func differOnlyInFinalNewline(_ a: [UInt8], _ b: [UInt8], _ mode: WhitespaceMode) -> Bool {
        func body(_ x: [UInt8]) -> [UInt8] {
            var x = x
            if x.last == 10 { x.removeLast() }
            if x.last == 13 { x.removeLast() }
            return x
        }
        let terminated = { (x: [UInt8]) in x.last == 10 || x.last == 13 }
        return mode != .exact && terminated(a) != terminated(b)
            && TextDiff.diff(body(a) + [10], body(b) + [10], options: DiffOptions(whitespace: mode)).isIdentical
    }

    @Test func foldingTheCommonPrefixAndSuffixGivesTheSameHunks() {
        // Short alphabets make long shared runs, repeated tokens and
        // boundaries inside words and blanks likely.
        let pieces: [[UInt8]] = ["a", "b", "ab", " ", "  ", "\t", ".", ",", "é", "x1", "_"].map { Array($0.utf8) }
        let terminators: [[UInt8]] = [[10], [13, 10], [13], []]
        var rng = SplitMix64(seed: 77)
        func random(_ n: Int) -> [UInt8] {
            var out: [UInt8] = []
            for _ in 0 ..< n { out += pieces[Int(rng.next() % UInt64(pieces.count))] }
            return out
        }
        var failures = 0
        for iteration in 0 ..< 6000 {
            let shared = random(Int(rng.next() % 12)), tail = random(Int(rng.next() % 12))
            var a = shared + random(Int(rng.next() % 6)) + tail
            var b = shared + random(Int(rng.next() % 6)) + tail
            if iteration % 7 == 0 { b = a + random(Int(rng.next() % 3)) }
            a += terminators[Int(rng.next() % 4)]
            b += terminators[Int(rng.next() % 4)]
            for ws in 0 ... 2 {
                let mode = WhitespaceMode(rawValue: ws)!
                let result = TextDiff.diff(a, b, options: DiffOptions(whitespace: mode))
                let expected = Self.referenceHunks(a, b, ws: ws)
                // Lines equal under the mode give no mixed block at all, and
                // lines that differ only in having a final newline get the
                // end-of-file hunk (EOFTests), not a token diff.
                guard result.blocks.count == 1, result.blocks[0].kind != .equal,
                      !Self.differOnlyInFinalNewline(a, b, mode) else { continue }
                let actual = result.blocks[0].kind == .change ? result.blocks[0].words : nil
                if actual != expected {
                    failures += 1
                    if failures <= 3 {
                        Issue.record("ws=\(ws) a=\(a) b=\(b): \(String(describing: actual)) != \(String(describing: expected))")
                    }
                }
            }
        }
        #expect(failures == 0)
    }
}
