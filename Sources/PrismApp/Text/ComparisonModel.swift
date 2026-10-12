// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation

/// One side of a comparison: its bytes, line index and the intra-line
/// highlights of its changed lines.
struct ComparisonSide: Sendable {
    let bytes: [UInt8]
    let lines: LineIndex
    let hasFinalNewline: Bool
    /// Widest line, in display columns (see `advance`). Used to size the document view.
    let maxColumns: Int
    /// Display columns of each line (same rules as `maxColumns`), for the
    /// wrapped heights.
    let lineColumns: [Int32]
    /// True for each line made only of ASCII bytes (monospaced, so its
    /// width is exactly its columns); other lines are measured when wrapped.
    let lineIsASCII: [Bool]
    /// Byte columns, relative to the line start, of the word differences on
    /// each changed line. An empty range is an insertion point.
    let words: [Int: [Range<Int>]]

    var lineCount: Int { lines.count }

    /// Byte range of line `i` without its terminator.
    func contentRange(_ i: Int) -> Range<Int> {
        let range = lines.range(i)
        var end = range.upperBound
        if end > range.lowerBound, bytes[end - 1] == 0x0A { end -= 1 }
        if end > range.lowerBound, bytes[end - 1] == 0x0D { end -= 1 }
        return range.lowerBound ..< end
    }

    /// True when line `i` ends with a line terminator.
    func hasTerminator(_ i: Int) -> Bool {
        contentRange(i).upperBound < lines.range(i).upperBound
    }

    /// Text of line `i`, terminator excluded.
    func text(ofLine i: Int) -> String {
        let range = contentRange(i)
        return bytes.withUnsafeBufferPointer { buffer in
            String(decoding: UnsafeBufferPointer(rebasing: buffer[range]), as: UTF8.self)
        }
    }

    /// UTF-16 offset, within the text of line `i`, of byte column `column`.
    func utf16Offset(line i: Int, column: Int) -> Int {
        let start = lines.range(i).lowerBound
        let end = min(start + column, contentRange(i).upperBound)
        return UTF16Columns.count(bytes, from: start, to: max(start, end))
    }

    /// Display column after a character that starts with `byte`, at
    /// `column`. Tabs stop every 4 columns; three-byte sequences (which
    /// include the wide CJK ranges) take 2 columns and four-byte ones
    /// (emoji and other astral characters, often drawn from a wider
    /// fallback font) take 3. Continuation bytes add nothing.
    @inline(__always)
    static func advance(_ column: Int, _ byte: UInt8) -> Int {
        switch byte {
        case 0x09: (column / 4 + 1) * 4
        case 0x80 ... 0xBF: column
        case 0xE1 ... 0xEF: column + 2
        case 0xF0 ... 0xF4: column + 3
        default: column + 1
        }
    }

    /// Display columns of every line, terminator excluded.
    static func lineColumns(_ bytes: [UInt8], lines: LineIndex) -> [Int32] {
        var result = [Int32]()
        result.reserveCapacity(lines.count)
        bytes.withUnsafeBufferPointer { buffer in
            for i in 0 ..< lines.count {
                var column = 0
                for index in lines.range(i) {
                    let byte = buffer[index]
                    if byte == 0x0A || byte == 0x0D { continue }
                    column = advance(column, byte)
                }
                result.append(Int32(clamping: column))
            }
        }
        return result
    }

    /// Whether every line is all ASCII.
    static func lineASCII(_ bytes: [UInt8], lines: LineIndex) -> [Bool] {
        bytes.withUnsafeBufferPointer { buffer in
            (0 ..< lines.count).map { i in lines.range(i).allSatisfy { buffer[$0] < 0x80 } }
        }
    }

    /// Widest line in display columns.
    static func maxColumns(_ bytes: [UInt8]) -> Int {
        var widest = 0, column = 0
        for byte in bytes {
            if byte == 0x0A || byte == 0x0D {
                widest = max(widest, column)
                column = 0
            } else {
                column = advance(column, byte)
            }
        }
        return max(widest, column)
    }
}

/// A finished two-way comparison: both sides plus the Blocks layout. Built
/// off the main thread, then handed to the view.
struct ComparisonModel: Sendable {
    let a: ComparisonSide
    let b: ComparisonSide
    let layout: BlocksLayout
    let whitespace: WhitespaceMode
    /// Time spent in the diff engine, in milliseconds.
    let diffMilliseconds: Double

    func side(_ side: DiffSide) -> ComparisonSide { side == .a ? a : b }

    var changeCount: Int { layout.changes.count }

    /// Diffs two texts and builds the model. Throws `DiffError.cancelled`
    /// when `cancellation` fires.
    ///
    /// `resolved` lists line ranges (A, B) that a merge made identical; each
    /// one that falls inside unchanged text is split into its own block and
    /// stays in the list of changes, shown as resolved.
    static func build(a: LoadedText, b: LoadedText, whitespace: WhitespaceMode,
                      resolved: [(a: Range<Int>, b: Range<Int>)] = [],
                      cancellation: CancellationFlag? = nil) throws -> ComparisonModel {
        let options = DiffOptions(whitespace: whitespace, cancellation: cancellation)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try TextDiff.cancellableDiff(a.bytes, b.bytes, options: options)
        let diffMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        var wordsA = [Int: [Range<Int>]](), wordsB = [Int: [Range<Int>]]()
        for block in result.blocks where !block.words.isEmpty {
            for hunk in block.words {
                wordsA[hunk.aLine, default: []].append(hunk.a)
                wordsB[hunk.bLine, default: []].append(hunk.b)
            }
        }
        if cancellation?.isCancelled == true { throw DiffError.cancelled }
        let sideA = ComparisonSide(bytes: a.bytes, lines: result.linesA, hasFinalNewline: result.aHasFinalNewline,
                                   maxColumns: ComparisonSide.maxColumns(a.bytes),
                                   lineColumns: ComparisonSide.lineColumns(a.bytes, lines: result.linesA),
                                   lineIsASCII: ComparisonSide.lineASCII(a.bytes, lines: result.linesA), words: wordsA)
        let sideB = ComparisonSide(bytes: b.bytes, lines: result.linesB, hasFinalNewline: result.bHasFinalNewline,
                                   maxColumns: ComparisonSide.maxColumns(b.bytes),
                                   lineColumns: ComparisonSide.lineColumns(b.bytes, lines: result.linesB),
                                   lineIsASCII: ComparisonSide.lineASCII(b.bytes, lines: result.linesB), words: wordsB)
        let (blocks, resolvedBlocks) = Self.splitting(result.blocks, at: resolved)
        let layout = BlocksLayout(
            blocks: blocks,
            resolved: resolvedBlocks,
            lineCounts: (sideA.lineCount, sideB.lineCount),
            showsTrailer: (sideA.hasFinalNewline || sideA.lineCount == 0,
                           sideB.hasFinalNewline || sideB.lineCount == 0))
        return ComparisonModel(a: sideA, b: sideB, layout: layout, whitespace: whitespace, diffMilliseconds: diffMs)
    }

    /// Makes each region of `regions` (lines a merge resolved) a block of
    /// its own: unchanged blocks are split at the region's edges, and the
    /// blocks inside it become one unchanged block, listed as a resolved
    /// change. A region with no lines becomes an empty block at its place,
    /// so the change keeps its number. A region whose edges do not fall on
    /// block edges (the text around it changed) is left out. Returns the
    /// blocks and the indices of the region blocks.
    static func splitting(_ blocks: [DiffBlock], at regions: [(a: Range<Int>, b: Range<Int>)])
        -> ([DiffBlock], Set<Int>) {
        guard !regions.isEmpty else { return (blocks, []) }
        // 1. Cut unchanged blocks at every region edge that lies inside one.
        var edges = [(a: Int, b: Int)]()
        for region in regions {
            edges.append((region.a.lowerBound, region.b.lowerBound))
            edges.append((region.a.upperBound, region.b.upperBound))
        }
        var cut = [DiffBlock]()
        cut.reserveCapacity(blocks.count + edges.count)
        for block in blocks {
            guard block.kind == .equal else {
                cut.append(block)
                continue
            }
            let points = Set(edges.compactMap { edge -> Int? in
                let offset = edge.a - block.a.lowerBound
                guard edge.a > block.a.lowerBound, edge.a < block.a.upperBound,
                      edge.b - block.b.lowerBound == offset else { return nil }
                return offset
            }).sorted()
            var from = 0
            for offset in points + [block.a.count] where offset > from {
                cut.append(DiffBlock(kind: .equal, a: block.a.lowerBound + from ..< block.a.lowerBound + offset,
                                     b: block.b.lowerBound + from ..< block.b.lowerBound + offset))
                from = offset
            }
        }
        // 2. Replace the blocks of each region with one resolved block.
        let wanted = regions.sorted { ($0.a.lowerBound, $0.b.lowerBound) < ($1.a.lowerBound, $1.b.lowerBound) }
        var out = [DiffBlock]()
        out.reserveCapacity(cut.count + wanted.count)
        var resolved = Set<Int>()
        var next = 0
        var i = 0
        func emit(_ region: (a: Range<Int>, b: Range<Int>)) {
            resolved.insert(out.count)
            out.append(DiffBlock(kind: .equal, a: region.a, b: region.b))
        }
        while i < cut.count {
            let block = cut[i]
            // Regions that start before this block can no longer match.
            while next < wanted.count, (wanted[next].a.lowerBound, wanted[next].b.lowerBound)
                < (block.a.lowerBound, block.b.lowerBound) {
                next += 1
            }
            guard next < wanted.count, wanted[next].a.lowerBound == block.a.lowerBound,
                  wanted[next].b.lowerBound == block.b.lowerBound else {
                out.append(block)
                i += 1
                continue
            }
            let region = wanted[next]
            next += 1
            if region.a.isEmpty && region.b.isEmpty {
                emit(region)
                continue
            }
            var j = i
            while j < cut.count, cut[j].a.upperBound <= region.a.upperBound, cut[j].b.upperBound <= region.b.upperBound,
                  !(cut[j].a.upperBound == region.a.upperBound && cut[j].b.upperBound == region.b.upperBound) {
                j += 1
            }
            if j < cut.count, cut[j].a.upperBound == region.a.upperBound, cut[j].b.upperBound == region.b.upperBound {
                emit(region)
                i = j + 1
            }
        }
        // Empty regions at the very end of both texts.
        let end = (a: cut.last?.a.upperBound ?? 0, b: cut.last?.b.upperBound ?? 0)
        while next < wanted.count {
            let region = wanted[next]
            next += 1
            if region.a.isEmpty, region.b.isEmpty, region.a.lowerBound == end.a, region.b.lowerBound == end.b {
                emit(region)
            }
        }
        return (out, resolved)
    }

    /// The change to select for lines `a` and `b` (a merged region): the
    /// one that is exactly that region, else the first that shares lines
    /// with it, else one that touches it on both sides, else the nearest
    /// one after it.
    func change(covering a: Range<Int>, _ b: Range<Int>) -> Int? {
        let layout = self.layout
        guard !layout.changes.isEmpty else { return nil }
        if let exact = layout.changes.firstIndex(where: { layout.blocks[$0].a == a && layout.blocks[$0].b == b }) {
            return exact
        }
        func meets(_ x: Range<Int>, _ y: Range<Int>) -> Bool {
            x.lowerBound <= y.upperBound && y.lowerBound <= x.upperBound
        }
        if let shared = layout.changes.firstIndex(where: {
            layout.blocks[$0].a.overlaps(a) || layout.blocks[$0].b.overlaps(b)
        }) {
            return shared
        }
        if let overlap = layout.changes.firstIndex(where: { meets(layout.blocks[$0].a, a) && meets(layout.blocks[$0].b, b) }) {
            return overlap
        }
        if let after = layout.changes.firstIndex(where: { layout.blocks[$0].a.lowerBound >= a.lowerBound }) {
            return after
        }
        return layout.changes.count - 1
    }
}
