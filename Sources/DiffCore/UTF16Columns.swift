// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

// Byte offsets to UTF-16 offsets, for AppKit (NSString and NSRange count
// UTF-16 code units). Pure Swift, no Foundation.

/// Which input of a two-way diff.
public enum DiffSide: Sendable, Equatable {
    case a
    case b
}

/// UTF-16 counting over UTF-8 bytes.
///
/// A valid scalar counts 2 units when its lead byte is 0xF0-0xF4 (outside the
/// BMP, a surrogate pair) and 1 otherwise. Ill-formed input counts 1 unit
/// (one U+FFFD) per maximal subpart of an ill-formed sequence, the Unicode
/// "substitution of maximal subparts" rule that `String(decoding:as:)` uses,
/// so the counts equal `String(decoding: bytes, as: UTF8.self).utf16.count`.
public enum UTF16Columns {

    /// UTF-16 length of `p[start ..< end]` decoded on its own. A sequence cut
    /// by `end` counts as one replacement character, as it would when that
    /// slice is decoded.
    public static func count(_ p: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int {
        precondition(start >= 0 && start <= end && end <= p.count, "byte range out of bounds")
        var units = 0
        var i = start
        while i < end {
            let lead = p[i]
            if lead < 0x80 {
                units += 1
                i += 1
                continue
            }
            // Expected sequence length and the allowed range of the second
            // byte (which excludes overlongs, surrogates and > U+10FFFF).
            let length: Int, low: UInt8, high: UInt8
            switch lead {
            case 0xC2 ... 0xDF: (length, low, high) = (2, 0x80, 0xBF)
            case 0xE0: (length, low, high) = (3, 0xA0, 0xBF)
            case 0xE1 ... 0xEC, 0xEE ... 0xEF: (length, low, high) = (3, 0x80, 0xBF)
            case 0xED: (length, low, high) = (3, 0x80, 0x9F)
            case 0xF0: (length, low, high) = (4, 0x90, 0xBF)
            case 0xF1 ... 0xF3: (length, low, high) = (4, 0x80, 0xBF)
            case 0xF4: (length, low, high) = (4, 0x80, 0x8F)
            default:
                // A stray continuation byte or a byte that never starts a
                // sequence (0xC0, 0xC1, 0xF5-0xFF).
                units += 1
                i += 1
                continue
            }
            // Length of the well-formed prefix of this sequence.
            var valid = 1
            if i + 1 < end, p[i + 1] >= low, p[i + 1] <= high {
                valid = 2
                while valid < length, i + valid < end, p[i + valid] & 0xC0 == 0x80 { valid += 1 }
            }
            if valid == length {
                units += length == 4 ? 2 : 1
            } else {
                units += 1   // one replacement for the maximal subpart
            }
            i += valid
        }
        return units
    }

    /// `count` over an array.
    public static func count(_ bytes: [UInt8], from start: Int, to end: Int) -> Int {
        bytes.withUnsafeBufferPointer { count($0, from: start, to: end) }
    }
}

extension TextDiffResult {

    /// The line index of one side.
    public func lines(_ side: DiffSide) -> LineIndex {
        side == .a ? linesA : linesB
    }

    /// UTF-16 columns of one side of a word hunk, relative to the start of
    /// its line (as the byte columns are). `buffer` is that side's input.
    ///
    /// A column is the UTF-16 length of the line's bytes up to that byte
    /// column, so the range is exactly what `NSString` would use on the
    /// decoded line. O(length of the line).
    public func utf16Range(of hunk: WordHunk, side: DiffSide, in buffer: UnsafeBufferPointer<UInt8>) -> Range<Int> {
        let line = side == .a ? hunk.aLine : hunk.bLine
        let columns = side == .a ? hunk.a : hunk.b
        let start = lines(side).range(line).lowerBound
        let lower = UTF16Columns.count(buffer, from: start, to: start + columns.lowerBound)
        let upper = columns.isEmpty ? lower
            : UTF16Columns.count(buffer, from: start, to: start + columns.upperBound)
        return lower ..< upper
    }

    /// Array variant of `utf16Range(of:side:in:)`.
    public func utf16Range(of hunk: WordHunk, side: DiffSide, in buffer: [UInt8]) -> Range<Int> {
        buffer.withUnsafeBufferPointer { utf16Range(of: hunk, side: side, in: $0) }
    }

    /// UTF-16 offset of the start of `line` (0 ... line count, the last
    /// being the end of the buffer) in the whole decoded buffer. O(offset);
    /// callers mapping many lines should accumulate per-line
    /// `UTF16Columns.count` values instead.
    public func utf16LineStart(_ line: Int, side: DiffSide, in buffer: UnsafeBufferPointer<UInt8>) -> Int {
        UTF16Columns.count(buffer, from: 0, to: Int(lines(side).starts[line]))
    }

    /// Array variant of `utf16LineStart(_:side:in:)`.
    public func utf16LineStart(_ line: Int, side: DiffSide, in buffer: [UInt8]) -> Int {
        buffer.withUnsafeBufferPointer { utf16LineStart(line, side: side, in: $0) }
    }
}
