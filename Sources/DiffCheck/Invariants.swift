// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// Checks that a diff result is a valid, well-formed edit script.
///
/// Invariants:
/// - blocks tile A and B exactly, in order;
/// - each block's kind matches its ranges (equal and change are 1:1 and
///   non-empty, insert and delete have exactly one empty side);
/// - no two adjacent equal blocks and no two adjacent change blocks;
/// - equal lines compare equal under the whitespace-mode key;
/// - only change blocks carry word hunks, every hunk sits on one of the
///   block's line pairs, and hunks are ordered, disjoint and in bounds;
/// - applying a pair's hunks to its A line rebuilds the B line (byte for
///   byte at ws=0, ignoring terminators at ws=1, and ignoring terminators
///   and blanks at ws=2; see `rebuildKey`);
/// - at ws=0, applying the script to A rebuilds B byte for byte.
public enum InvariantChecker {

    /// Diffs `a` and `b` with `options` in parallel and serially, and returns
    /// every violation found (empty when the result is valid).
    public static func check(_ a: [UInt8], _ b: [UInt8], options: DiffOptions) -> [String] {
        var parallel = options
        parallel.parallel = true
        var serial = options
        serial.parallel = false
        let result = TextDiff.diff(a, b, options: parallel)
        var problems = violations(of: result, a, b, whitespace: options.whitespace)
        if TextDiff.diff(a, b, options: serial) != result {
            problems.append("serial result differs from parallel result")
        }
        return problems
    }

    /// The violations in `result`, the diff of `a` against `b`.
    public static func violations(of result: TextDiffResult, _ a: [UInt8], _ b: [UInt8],
                                  whitespace: WhitespaceMode) -> [String] {
        let ws = whitespace.rawValue
        var problems: [String] = []
        func fail(_ message: String) { problems.append(message) }

        let expectedA = referenceLineCount(a), expectedB = referenceLineCount(b)
        if result.linesA.count != expectedA || result.linesB.count != expectedB {
            fail("line index has \(result.linesA.count)/\(result.linesB.count) lines, expected \(expectedA)/\(expectedB)")
            return problems
        }

        var cursorA = 0, cursorB = 0
        var previous: BlockKind?
        var rebuilt: [UInt8] = []
        for (index, block) in result.blocks.enumerated() {
            let label = "block \(index) \(block.kind.rawValue) a\(block.a) b\(block.b)"
            guard block.a.lowerBound == cursorA, block.b.lowerBound == cursorB,
                  block.a.upperBound <= result.linesA.count, block.b.upperBound <= result.linesB.count else {
                fail("\(label): does not continue at a\(cursorA) b\(cursorB) or runs past the end")
                return problems
            }
            if block.kind != .change && !block.words.isEmpty { fail("\(label): word hunks outside a change") }
            switch block.kind {
            case .equal:
                if block.a.count != block.b.count || block.a.isEmpty { fail("\(label): not 1:1") }
                if previous == .equal { fail("\(label): follows another equal block") }
                for k in 0 ..< min(block.a.count, block.b.count) {
                    let la = line(a, result.linesA, block.a.lowerBound + k)
                    let lb = line(b, result.linesB, block.b.lowerBound + k)
                    if key(la, ws) != key(lb, ws) { fail("\(label): lines \(k) differ under ws=\(ws)") }
                }
            case .insert:
                if !block.a.isEmpty || block.b.isEmpty { fail("\(label): bad ranges for an insert") }
            case .delete:
                if block.a.isEmpty || !block.b.isEmpty { fail("\(label): bad ranges for a delete") }
            case .change:
                if block.a.count != block.b.count || block.a.isEmpty { fail("\(label): not 1:1") }
                if previous == .change { fail("\(label): follows another change block") }
                checkWords(block, label, a, b, result, ws, fail)
            }
            if block.kind == .equal {
                for k in block.a { rebuilt += line(a, result.linesA, k) }
            } else {
                for k in block.b { rebuilt += line(b, result.linesB, k) }
            }
            previous = block.kind
            cursorA = block.a.upperBound
            cursorB = block.b.upperBound
        }
        if cursorA != result.linesA.count || cursorB != result.linesB.count {
            fail("blocks end at a\(cursorA) b\(cursorB), files have \(result.linesA.count)/\(result.linesB.count) lines")
        }
        if ws == 0 && problems.isEmpty && rebuilt != b { fail("the script does not rebuild B") }
        return problems
    }

    private static func checkWords(_ block: DiffBlock, _ label: String, _ a: [UInt8], _ b: [UInt8],
                                   _ result: TextDiffResult, _ ws: Int, _ fail: (String) -> Void) {
        for hunk in block.words {
            let offset = hunk.aLine - block.a.lowerBound
            if !block.a.contains(hunk.aLine) || hunk.bLine != block.b.lowerBound + offset {
                fail("\(label): hunk on a\(hunk.aLine)/b\(hunk.bLine) is not on a pair of the block")
            }
        }
        for k in 0 ..< min(block.a.count, block.b.count) {
            let la = block.a.lowerBound + k, lb = block.b.lowerBound + k
            let lineA = Array(line(a, result.linesA, la)), lineB = Array(line(b, result.linesB, lb))
            var out: [UInt8] = []
            var position = 0
            var valid = true
            for hunk in block.words where hunk.aLine == la {
                guard hunk.a.lowerBound >= position, hunk.a.upperBound <= lineA.count,
                      hunk.b.lowerBound >= 0, hunk.b.upperBound <= lineB.count else {
                    fail("\(label): hunk \(hunk.a)->\(hunk.b) on a\(la) overlaps or is out of bounds")
                    valid = false
                    break
                }
                out += lineA[position ..< hunk.a.lowerBound]
                out += lineB[hunk.b]
                position = hunk.a.upperBound
            }
            guard valid else { continue }
            out += lineA[position...]
            if rebuildKey(out, ws) != rebuildKey(lineB, ws) {
                fail("\(label): word hunks do not rebuild b\(lb) under ws=\(ws)")
            }
        }
    }

    /// Line `i` of `buffer`, terminator included.
    static func line(_ buffer: [UInt8], _ index: LineIndex, _ i: Int) -> ArraySlice<UInt8> {
        buffer[index.range(i)]
    }

    /// Reference line key, written independently of the engine.
    public static func key(_ line: ArraySlice<UInt8>, _ ws: Int) -> [UInt8] {
        var bytes = Array(line)
        if ws >= 1 {
            if bytes.last == 10 { bytes.removeLast() }
            if bytes.last == 13 { bytes.removeLast() }
        }
        if ws == 2 {
            while let first = bytes.first, first == 32 || first == 9 { bytes.removeFirst() }
            while let last = bytes.last, last == 32 || last == 9 { bytes.removeLast() }
        }
        return bytes
    }

    /// What a rebuilt line must agree on with the real B line.
    ///
    /// At ws=1 terminators are dropped wherever they ended up. At ws=2 edge
    /// blanks are not tokenised, so a hunk next to them can turn one side's
    /// trailing blanks into interior ones in the rebuilt line (for example A
    /// "x  \n" against B "x y": the B-only " y" replaces A's terminator,
    /// after A's ignored blanks); blanks are therefore dropped entirely and
    /// only the non-blank content must be rebuilt. Interior blank runs are
    /// still checked exactly by the ws=0 and ws=1 runs of the same case.
    static func rebuildKey(_ line: [UInt8], _ ws: Int) -> [UInt8] {
        switch ws {
        case 0: line
        case 1: line.filter { $0 != 10 && $0 != 13 }
        default: line.filter { $0 != 10 && $0 != 13 && $0 != 32 && $0 != 9 }
        }
    }

    /// Reference line count (LF, CRLF and CR terminators).
    static func referenceLineCount(_ buffer: [UInt8]) -> Int {
        var lines = 0
        var i = 0
        var open = false
        while i < buffer.count {
            open = true
            if buffer[i] == 10 {
                lines += 1
                open = false
            } else if buffer[i] == 13 {
                if i + 1 < buffer.count && buffer[i + 1] == 10 { i += 1 }
                lines += 1
                open = false
            }
            i += 1
        }
        return lines + (open ? 1 : 0)
    }

    /// Reference split into lines, terminators included.
    public static func referenceLines(_ buffer: [UInt8]) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = 0, i = 0
        while i < buffer.count {
            if buffer[i] == 10 || buffer[i] == 13 {
                if buffer[i] == 13 && i + 1 < buffer.count && buffer[i + 1] == 10 { i += 1 }
                lines.append(buffer[start ... i])
                start = i + 1
            }
            i += 1
        }
        if start < buffer.count { lines.append(buffer[start...]) }
        return lines
    }

    /// Length of the longest common subsequence of two key lists (dynamic
    /// programming, O(n*m)); the optimum the engine's equal lines are
    /// measured against.
    public static func lcsLength(_ a: [[UInt8]], _ b: [[UInt8]]) -> Int {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        var previousRow = [Int](repeating: 0, count: b.count + 1)
        var row = previousRow
        for i in 1 ... a.count {
            for j in 1 ... b.count {
                row[j] = a[i - 1] == b[j - 1] ? previousRow[j - 1] + 1 : max(previousRow[j], row[j - 1])
            }
            swap(&previousRow, &row)
        }
        return previousRow[b.count]
    }
}
