// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import CoreText
import DiffCore

/// One line of one side, prepared for drawing.
///
/// A line is cut into chunks of about `LineShaper.chunkLength` UTF-16 units
/// and each chunk is shaped into its own `CTLine` only when part of it is
/// drawn, so a multi-megabyte line costs no more per frame than the slice
/// that is on screen. Only the most recently used chunks stay shaped.
///
/// Cuts fall between two ASCII characters, preferably at a tab stop (a
/// multiple of four columns, so tabs inside a chunk land where they would in
/// the whole line). A run of non-ASCII text with no such place is cut at a
/// character (grapheme cluster) boundary, so no cluster is ever split.
///
/// Placement: an all-ASCII line is monospaced, so chunk `i` starts at
/// `column × charWidth`. Any other line with several chunks has every
/// chunk's shaped width measured once, and chunks are placed by the running
/// sum of those widths.
@MainActor
final class ShapedLine {
    struct Chunk {
        /// First UTF-16 unit, display column and byte (relative to the line).
        let utf16: Int
        let column: Int
        let byte: Int
    }

    /// The chunks, then a sentinel holding the line's totals.
    let chunks: [Chunk]
    /// Word differences as UTF-16 ranges within the line.
    let words: [Range<Int>]
    /// True when every byte of the line is ASCII.
    let isASCII: Bool
    /// Measured x of every chunk start, then the line width (non-ASCII
    /// lines with several chunks, once measured).
    fileprivate var offsets: [Float]?
    /// Shaped chunks, most recently used last.
    fileprivate var shaped: [Int: CTLine] = [:]
    fileprivate var recent: [Int] = []
    /// The line's text, for character boundaries (made on demand).
    fileprivate var string: NSString?

    fileprivate init(chunks: [Chunk], words: [Range<Int>], isASCII: Bool) {
        self.chunks = chunks
        self.words = words
        self.isASCII = isASCII
    }

    var chunkCount: Int { chunks.count - 1 }
    var utf16Count: Int { chunks[chunks.count - 1].utf16 }
    var columns: Int { chunks[chunks.count - 1].column }
    /// Number of chunks shaped right now (tests).
    var shapedCount: Int { shaped.count }
    /// True when chunks are placed by measured width.
    var isMeasured: Bool { offsets != nil }

    /// The chunk holding UTF-16 offset `offset` (the last one for the end).
    func chunk(atUTF16 offset: Int) -> Int {
        var low = 0, high = chunkCount - 1
        while low < high {
            let mid = (low + high + 1) >> 1
            if chunks[mid].utf16 <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Shapes and caches the lines of one side of a comparison.
@MainActor
final class LineShaper {
    /// Target chunk size in UTF-16 units.
    static let chunkLength = 2048
    /// Past this many units without a safe ASCII cut, cut at the next
    /// character boundary.
    static let forcedChunkLength = 2048 + 256
    /// Lines kept prepared; beyond that the lines far from the one being
    /// drawn are dropped.
    static let cacheLimit = 4096
    /// Chunks kept shaped per line.
    static let shapedChunksPerLine = 16

    let text: ComparisonSide
    let metrics: TextMetrics
    private let attributes: [NSAttributedString.Key: Any]
    private var cache: [Int: ShapedLine] = [:]
    private var endMarkLine: CTLine?
    /// Measured widths of whole lines (non-ASCII lines, for wrapping).
    private var measuredWidths: [Int: CGFloat] = [:]

    init(text: ComparisonSide, metrics: TextMetrics) {
        self.text = text
        self.metrics = metrics
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = metrics.charWidth * 4
        attributes = [
            .font: metrics.font,
            .paragraphStyle: paragraph,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
    }

    var charWidth: CGFloat { metrics.charWidth }

    /// The prepared line `line` (cached).
    func line(_ line: Int) -> ShapedLine {
        if let cached = cache[line] { return cached }
        if cache.count >= Self.cacheLimit {
            // Keep the lines around the one being drawn; scrolling back a
            // little should not reshape what was just on screen.
            cache = cache.filter { abs($0.key - line) < Self.cacheLimit / 4 }
        }
        let prepared = prepare(line)
        cache[line] = prepared
        return prepared
    }

    private func prepare(_ line: Int) -> ShapedLine {
        let range = text.contentRange(line)
        let start = range.lowerBound
        var endpoints = Set<Int>()
        let wordColumns = text.words[line] ?? []
        for word in wordColumns {
            endpoints.insert(min(word.lowerBound, range.count))
            endpoints.insert(min(word.upperBound, range.count))
        }
        let sortedEndpoints = endpoints.sorted()
        var utf16At = [Int: Int]()
        var nextEndpoint = 0
        var chunks = [ShapedLine.Chunk(utf16: 0, column: 0, byte: 0)]
        var utf16 = 0, column = 0
        var ascii = true
        text.bytes.withUnsafeBufferPointer { bytes in
            var i = start
            while i < range.upperBound {
                let byte = bytes[i]
                let offset = i - start
                if byte >= 0x80 { ascii = false }
                if byte & 0xC0 != 0x80 {
                    while nextEndpoint < sortedEndpoints.count, sortedEndpoints[nextEndpoint] <= offset {
                        utf16At[sortedEndpoints[nextEndpoint]] = utf16
                        nextEndpoint += 1
                    }
                    let length = utf16 - chunks[chunks.count - 1].utf16
                    if length >= Self.chunkLength, i > start {
                        let between = byte < 0x80 && bytes[i - 1] < 0x80
                        if between && (column % 4 == 0 || length >= Self.chunkLength + 64)
                            || length >= Self.forcedChunkLength
                            && Self.isCharacterBoundary(bytes, at: i, in: range) {
                            chunks.append(.init(utf16: utf16, column: column, byte: offset))
                        }
                    }
                    utf16 += byte >= 0xF0 ? 2 : 1
                    column = ComparisonSide.advance(column, byte)
                }
                i += 1
            }
        }
        while nextEndpoint < sortedEndpoints.count {
            utf16At[sortedEndpoints[nextEndpoint]] = utf16
            nextEndpoint += 1
        }
        chunks.append(.init(utf16: utf16, column: column, byte: range.count))
        let words = wordColumns.map { word -> Range<Int> in
            let low = utf16At[min(word.lowerBound, range.count)] ?? utf16
            let high = utf16At[min(word.upperBound, range.count)] ?? utf16
            return low ..< max(low, high)
        }
        return ShapedLine(chunks: chunks, words: words, isASCII: ascii)
    }

    /// True when byte `index` (a scalar start) begins a character: decides
    /// on a small window of text around it.
    private static func isCharacterBoundary(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int,
                                            in range: Range<Int>) -> Bool {
        var from = max(range.lowerBound, index - 64)
        while from > range.lowerBound, bytes[from] & 0xC0 == 0x80 { from -= 1 }
        var to = min(range.upperBound, index + 64)
        while to < range.upperBound, bytes[to] & 0xC0 == 0x80 { to += 1 }
        let window = String(decoding: UnsafeBufferPointer(rebasing: bytes[from ..< to]), as: UTF8.self)
        var position = from
        for character in window {
            if position == index { return true }
            if position > index { return false }
            position += character.utf8.count
        }
        return position == index
    }

    // MARK: shaped chunks

    /// The `CTLine` of chunk `index` of line `line`, shaped on first use.
    /// Only the most recently used chunks of a line stay shaped.
    func ctLine(_ shaped: ShapedLine, line: Int, chunk index: Int) -> CTLine {
        if let done = shaped.shaped[index] {
            if shaped.recent.last != index, let position = shaped.recent.firstIndex(of: index) {
                shaped.recent.remove(at: position)
                shaped.recent.append(index)
            }
            return done
        }
        let made = makeLine(shaped, line: line, chunk: index)
        if shaped.recent.count >= Self.shapedChunksPerLine {
            shaped.shaped[shaped.recent.removeFirst()] = nil
        }
        shaped.shaped[index] = made
        shaped.recent.append(index)
        return made
    }

    private func makeLine(_ shaped: ShapedLine, line: Int, chunk index: Int) -> CTLine {
        let base = text.contentRange(line).lowerBound
        let from = base + shaped.chunks[index].byte, to = base + shaped.chunks[index + 1].byte
        let string = text.bytes.withUnsafeBufferPointer { buffer in
            String(decoding: UnsafeBufferPointer(rebasing: buffer[from ..< to]), as: UTF8.self)
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Measures every chunk of a non-ASCII multi-chunk line, once.
    private func measure(_ shaped: ShapedLine, line: Int) -> [Float] {
        if let offsets = shaped.offsets { return offsets }
        var offsets = [Float](repeating: 0, count: shaped.chunks.count)
        var x: Double = 0
        for index in 0 ..< shaped.chunkCount {
            offsets[index] = Float(x)
            autoreleasepool {
                let line = shaped.shaped[index] ?? makeLine(shaped, line: line, chunk: index)
                x += CTLineGetTypographicBounds(line, nil, nil, nil)
            }
        }
        offsets[shaped.chunkCount] = Float(x)
        shaped.offsets = offsets
        return offsets
    }

    /// Unwrapped x where chunk `index` starts.
    func chunkX(_ shaped: ShapedLine, line: Int, chunk index: Int) -> CGFloat {
        if index == 0 { return 0 }
        if shaped.isASCII { return CGFloat(shaped.chunks[index].column) * charWidth }
        return CGFloat(measure(shaped, line: line)[index])
    }

    /// The chunk under unwrapped x `x`.
    func chunk(atX x: CGFloat, in shaped: ShapedLine, line: Int) -> Int {
        guard shaped.chunkCount > 1 else { return 0 }
        var low = 0, high = shaped.chunkCount - 1
        if shaped.isASCII {
            let column = Int(x / charWidth)
            while low < high {
                let mid = (low + high + 1) >> 1
                if shaped.chunks[mid].column <= column { low = mid } else { high = mid - 1 }
            }
            return low
        }
        let offsets = measure(shaped, line: line)
        let target = Float(x)
        while low < high {
            let mid = (low + high + 1) >> 1
            if offsets[mid] <= target { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Unwrapped x range covering UTF-16 offsets `lower ..< upper`, to
    /// whole-chunk precision and without shaping anything new: for cheap
    /// visibility tests.
    func roughRange(_ lower: Int, _ upper: Int, in shaped: ShapedLine, line: Int) -> ClosedRange<CGFloat> {
        let first = shaped.chunk(atUTF16: lower), last = shaped.chunk(atUTF16: upper)
        let from = chunkX(shaped, line: line, chunk: first)
        let to = last + 1 < shaped.chunkCount ? chunkX(shaped, line: line, chunk: last + 1) : .greatestFiniteMagnitude
        return from ... max(from, to)
    }

    /// Unwrapped x of UTF-16 offset `offset`, from the text origin.
    func x(ofOffset offset: Int, in shaped: ShapedLine, line: Int) -> CGFloat {
        let index = shaped.chunk(atUTF16: offset)
        let chunk = shaped.chunks[index]
        let local = CTLineGetOffsetForStringIndex(ctLine(shaped, line: line, chunk: index), offset - chunk.utf16, nil)
        return chunkX(shaped, line: line, chunk: index) + local
    }

    /// UTF-16 offset nearest to unwrapped x `x`, on a character boundary.
    func offset(atX x: CGFloat, in shaped: ShapedLine, line: Int) -> Int {
        if x <= 0 { return 0 }
        let index = chunk(atX: x, in: shaped, line: line)
        let chunk = shaped.chunks[index]
        let local = CTLineGetStringIndexForPosition(ctLine(shaped, line: line, chunk: index),
                                                    CGPoint(x: x - chunkX(shaped, line: line, chunk: index), y: 0))
        if local == kCFNotFound { return chunk.utf16 }
        return snap(min(chunk.utf16 + local, shaped.utf16Count), in: shaped, line: line)
    }

    /// Unwrapped width of the whole line.
    func width(of shaped: ShapedLine, line: Int) -> CGFloat {
        let last = shaped.chunkCount - 1
        if !shaped.isASCII, last > 0 { return CGFloat(measure(shaped, line: line)[last + 1]) }
        return chunkX(shaped, line: line, chunk: last)
            + CGFloat(CTLineGetTypographicBounds(ctLine(shaped, line: line, chunk: last), nil, nil, nil))
    }

    /// Measured width of line `line` (cached), for wrapping lines that are
    /// not monospaced ASCII.
    func measuredWidth(ofLine line: Int) -> CGFloat {
        if let known = measuredWidths[line] { return known }
        let value = width(of: self.line(line), line: line)
        measuredWidths[line] = value
        return value
    }

    // MARK: characters

    /// The line's text as an `NSString` (kept with the prepared line).
    func string(_ shaped: ShapedLine, line: Int) -> NSString {
        if let string = shaped.string { return string }
        let made = text.text(ofLine: line) as NSString
        shaped.string = made
        return made
    }

    /// `offset` moved back to the start of the character it falls in.
    func snap(_ offset: Int, in shaped: ShapedLine, line: Int) -> Int {
        guard !shaped.isASCII, offset > 0, offset < shaped.utf16Count else { return offset }
        return string(shaped, line: line).rangeOfComposedCharacterSequence(at: offset).location
    }

    /// The first character boundary at or after `offset`.
    func snapForward(_ offset: Int, in shaped: ShapedLine, line: Int) -> Int {
        guard !shaped.isASCII, offset > 0, offset < shaped.utf16Count else { return offset }
        let range = string(shaped, line: line).rangeOfComposedCharacterSequence(at: offset)
        return range.location == offset ? offset : range.location + range.length
    }

    // MARK: drawing

    /// Draws the chunks of a line that intersect the unwrapped range
    /// `visible`, the line origin at `origin` (x of the line start, baseline y).
    func draw(_ shaped: ShapedLine, line: Int, in context: CGContext, origin: CGPoint, visible: Range<CGFloat>) {
        guard shaped.utf16Count > 0 else { return }
        var index = chunk(atX: max(0, visible.lowerBound), in: shaped, line: line)
        // A glyph can overhang its chunk's start: draw the previous chunk too.
        if index > 0 { index -= 1 }
        while index < shaped.chunkCount {
            let chunkX = chunkX(shaped, line: line, chunk: index)
            if chunkX > visible.upperBound { break }
            context.textPosition = CGPoint(x: origin.x + chunkX, y: origin.y)
            CTLineDraw(ctLine(shaped, line: line, chunk: index), context)
            index += 1
        }
    }

    /// The "¬" drawn after changed lines.
    var endMark: CTLine {
        if let endMarkLine { return endMarkLine }
        let mark = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{00AC}", attributes: attributes))
        endMarkLine = mark
        return mark
    }
}
