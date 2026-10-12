// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// `prism diff --side-by-side`: A on the left, B on the right, one row per
/// line pair.
///
/// Each row is
///
///     <A number> <A text> <marker> <B number> <B text>
///
/// where each half (number, space, text) is `(width - 3) / 2` cells wide and
/// the marker is a space for equal lines, `<` for a deleted line, `>` for an
/// inserted line and `|` for a changed pair. Numbers are 1-based and
/// right-aligned. Tabs expand to the next multiple of 8, other control
/// characters show as `?`, and text that does not fit ends with `…`.
/// Trailing blanks of a row are not written. Every line of both files is
/// shown, even when the files compare equal.
struct SideBySideRenderer {
    static let tabStop = 8
    static let ellipsis: Character = "…"

    let width: Int
    let palette: Palette

    func write(_ result: TextDiffResult, a: [UInt8], b: [UInt8], to out: inout ChunkedOutput) {
        let numberWidth = String(max(result.linesA.count, result.linesB.count, 1)).count
        let half = (width - 3) / 2
        let textWidth = max(1, half - numberWidth - 1)
        let layout = Layout(numberWidth: numberWidth, textWidth: textWidth, palette: palette)
        let highlights = HighlightIndex(result.blocks)

        for block in result.blocks {
            let color = palette.color(for: block.kind)
            switch block.kind {
            case .equal, .change:
                let marker: Character = block.kind == .equal ? " " : "|"
                for k in 0 ..< block.a.count {
                    let la = block.a.lowerBound + k, lb = block.b.lowerBound + k
                    let left = Side(number: la, line: LineBytes(a, result.linesA.range(la)),
                                    highlights: highlights.a[la] ?? [], color: color)
                    let right = Side(number: lb, line: LineBytes(b, result.linesB.range(lb)),
                                     highlights: highlights.b[lb] ?? [], color: color)
                    out.append(layout.row(left, marker, right))
                }
            case .delete:
                for la in block.a {
                    let left = Side(number: la, line: LineBytes(a, result.linesA.range(la)),
                                    highlights: [], color: color)
                    out.append(layout.row(left, "<", nil))
                }
            case .insert:
                for lb in block.b {
                    let right = Side(number: lb, line: LineBytes(b, result.linesB.range(lb)),
                                     highlights: [], color: color)
                    out.append(layout.row(nil, ">", right))
                }
            }
        }
    }

    /// One side of a row: a 0-based line number and its bytes.
    struct Side {
        let number: Int
        let line: LineBytes
        let highlights: [Range<Int>]
        let color: String?
    }

    struct Layout {
        let numberWidth: Int
        let textWidth: Int
        let palette: Palette

        /// A full row, newline included, without trailing blanks.
        func row(_ left: Side?, _ marker: Character, _ right: Side?) -> String {
            var text = ""
            text.reserveCapacity(2 * (numberWidth + textWidth) + 8)
            let (leftText, leftCells) = cell(left)
            text += leftText
            text += String(repeating: " ", count: numberWidth + 1 + textWidth - leftCells)
            text += " " + String(marker) + " "
            text += cell(right).text
            while text.last == " " { text.removeLast() }
            return text + "\n"
        }

        /// Number, space and text of one side, and its width in cells.
        private func cell(_ side: Side?) -> (text: String, cells: Int) {
            guard let side else { return ("", 0) }
            let number = String(side.number + 1)
            let pad = String(repeating: " ", count: numberWidth - number.count)
            let (body, cells) = DisplayText.render(side.line.content, highlights: side.highlights,
                                                   width: textWidth, color: side.color, palette: palette)
            return (pad + number + " " + body, numberWidth + 1 + cells)
        }
    }
}

/// Terminal rendering of a line's content into a fixed number of cells.
enum DisplayText {

    /// The content laid out in at most `width` cells, styled when the
    /// palette is enabled, and the number of cells it takes.
    static func render(_ content: ArraySlice<UInt8>, highlights: [Range<Int>], width: Int,
                       color: String?, palette: Palette) -> (text: String, cells: Int) {
        let styled = palette.enabled && color != nil
        if !styled && content.count <= width && content.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            // Plain printable ASCII that fits: one cell per byte.
            return (String(decoding: content, as: UTF8.self), content.count)
        }
        let pieces = LineSegments(content: content, highlights: highlights).pieces
        // Lay out glyphs only until the text is known not to fit: one glyph
        // past `width` cells decides truncation, so a multi-megabyte line
        // costs no more than a short one.
        var glyphs: [(text: String, cells: Int, piece: Int)] = []
        var column = 0
        layout: for (index, piece) in pieces.enumerated() {
            var bytes = piece.bytes.makeIterator()
            var decoder = UTF8()
            while true {
                let scalar: Unicode.Scalar
                switch decoder.decode(&bytes) {
                case .scalarValue(let value): scalar = value
                case .error: scalar = "\u{FFFD}"
                case .emptyInput: continue layout
                }
                let (text, cells) = glyph(scalar, column: column)
                glyphs.append((text, cells, index))
                column += cells
                if column > width { break layout }
            }
        }
        let limit = column > width ? width - 1 : width
        var out = ""
        var used = 0
        var currentPiece = -1
        for glyph in glyphs {
            if used + glyph.cells > limit { break }
            if styled && glyph.piece != currentPiece {
                currentPiece = glyph.piece
                out += palette.prefix(color: color, highlighted: pieces[glyph.piece].highlighted)
            }
            out += glyph.text
            used += glyph.cells
        }
        if column > width {
            if styled { out += palette.prefix(color: color, highlighted: false) }
            out.append(SideBySideRenderer.ellipsis)
            used += 1
        }
        if styled && !out.isEmpty { out += Palette.reset }
        return (out, used)
    }

    /// The text shown for one scalar at `column`, and its width in cells.
    static func glyph(_ scalar: Unicode.Scalar, column: Int) -> (String, Int) {
        let value = scalar.value
        if value == 9 {
            let cells = SideBySideRenderer.tabStop - column % SideBySideRenderer.tabStop
            return (String(repeating: " ", count: cells), cells)
        }
        if value < 0x20 || value == 0x7F || (value >= 0x80 && value < 0xA0) { return ("?", 1) }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return (String(scalar), 0)
        default: break
        }
        return (String(scalar), isWide(value) ? 2 : 1)
    }

    /// East Asian wide and fullwidth ranges, plus the common emoji blocks.
    /// An approximation: the standard library has no width property.
    static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF, 0x3400 ... 0x4DBF,
             0x4E00 ... 0x9FFF, 0xA000 ... 0xA4CF, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF,
             0xFE30 ... 0xFE4F, 0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6,
             0x1F300 ... 0x1F64F, 0x1F900 ... 0x1F9FF, 0x20000 ... 0x3FFFD:
            return true
        default:
            return false
        }
    }
}
