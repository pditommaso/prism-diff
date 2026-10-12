// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// ANSI terminal styling for `prism diff --color`.
///
/// Colours follow the block kind: green for inserted lines, red for deleted
/// lines and yellow for changed line pairs. Inside changed lines the word
/// hunks are shown in reverse video. Without `--color` no escape sequence is
/// ever written.
struct Palette {
    static let escape = "\u{1B}["
    static let reset = escape + "0m"
    static let bold = escape + "1m"
    static let reverse = escape + "7m"
    static let red = escape + "31m"
    static let green = escape + "32m"
    static let yellow = escape + "33m"
    static let cyan = escape + "36m"

    /// False: every method returns plain text.
    let enabled: Bool

    /// The colour of a block's lines, or nil for equal lines.
    func color(for kind: BlockKind) -> String? {
        guard enabled else { return nil }
        switch kind {
        case .equal: return nil
        case .insert: return Self.green
        case .delete: return Self.red
        case .change: return Self.yellow
        }
    }

    /// `text` wrapped in `style` and a reset, or `text` when disabled.
    func wrap(_ text: String, _ style: String) -> String {
        enabled ? style + text + Self.reset : text
    }

    /// The SGR prefix for a piece of a line in `color`, highlighted or not.
    func prefix(color: String?, highlighted: Bool) -> String {
        guard enabled else { return "" }
        return Self.reset + (color ?? "") + (highlighted ? Self.reverse : "")
    }
}

/// A line's displayable content split at word-hunk boundaries.
///
/// `highlights` are byte columns relative to the line start, as in
/// `WordHunk`; they are clamped to the content (the terminator is never
/// highlighted), and empty ranges (insertion points) are dropped.
struct LineSegments {
    /// Pieces of the content in order, each flagged as highlighted or not.
    let pieces: [(bytes: ArraySlice<UInt8>, highlighted: Bool)]

    init(content: ArraySlice<UInt8>, highlights: [Range<Int>]) {
        let base = content.startIndex
        let length = content.count
        var pieces: [(ArraySlice<UInt8>, Bool)] = []
        var cursor = 0
        for range in highlights {
            let lower = min(max(range.lowerBound, cursor), length)
            let upper = min(range.upperBound, length)
            guard lower < upper else { continue }
            if lower > cursor { pieces.append((content[base + cursor ..< base + lower], false)) }
            pieces.append((content[base + lower ..< base + upper], true))
            cursor = upper
        }
        if cursor < length || pieces.isEmpty {
            pieces.append((content[base + cursor ..< base + length], false))
        }
        self.pieces = pieces
    }
}

/// Byte layout of one input line.
struct LineBytes {
    /// The line without its terminator.
    let content: ArraySlice<UInt8>
    /// LF, CRLF, CR, or empty for an unterminated last line.
    let terminator: ArraySlice<UInt8>

    init(_ buffer: [UInt8], _ range: Range<Int>) {
        var end = range.upperBound
        if end > range.lowerBound && buffer[end - 1] == 10 { end -= 1 }
        if end > range.lowerBound && buffer[end - 1] == 13 { end -= 1 }
        content = buffer[range.lowerBound ..< end]
        terminator = buffer[end ..< range.upperBound]
    }
}

/// Word-hunk byte columns of changed lines, keyed by line number.
struct HighlightIndex {
    private(set) var a: [Int: [Range<Int>]] = [:]
    private(set) var b: [Int: [Range<Int>]] = [:]

    init(_ blocks: [DiffBlock]) {
        for block in blocks where block.kind == .change {
            for hunk in block.words {
                if !hunk.a.isEmpty { a[hunk.aLine, default: []].append(hunk.a) }
                if !hunk.b.isEmpty { b[hunk.bLine, default: []].append(hunk.b) }
            }
        }
    }
}
