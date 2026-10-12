// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// Fixed-height line metrics of the text panes. Every row has the same
/// height, which is what keeps y(row) and row(y) exact and O(1).
struct TextMetrics {
    let font: NSFont
    let numberFont: NSFont
    /// Height of one row, in points (whole points, so rows never blur).
    let lineHeight: CGFloat
    /// From the top of a row to the text baseline.
    let baseline: CGFloat
    /// Advance of one character of the (monospaced) font.
    let charWidth: CGFloat
    /// Space above the first row.
    let topInset: CGFloat
    /// Left margin of the text inside its pane.
    let textInset: CGFloat = 8

    init(font: NSFont) {
        self.font = font
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(font.pointSize - 1, 6), weight: .regular)
        let ascent = font.ascender, descent = -font.descender
        lineHeight = ceil(ascent + descent + font.leading) + 4
        baseline = ((lineHeight - (ascent + descent)) / 2 + ascent).rounded()
        let glyph = font.glyph(withName: "M")
        let advance = font.advancement(forGlyph: glyph).width
        charWidth = advance > 0 ? advance : font.pointSize * 0.6
        topInset = lineHeight
    }

    /// Top of `row`.
    func y(ofRow row: Int) -> CGFloat { topInset + CGFloat(row) * lineHeight }

    /// The row at `y` (may be negative or past the end; callers clamp).
    func row(atY y: CGFloat) -> Int { Int(floor((y - topInset) / lineHeight)) }

    /// Rows that intersect `minY ..< maxY`, clamped to `0 ..< rowCount`.
    func rows(in minY: CGFloat, _ maxY: CGFloat, rowCount: Int) -> Range<Int> {
        let first = max(0, row(atY: minY))
        let last = min(rowCount, row(atY: maxY) + 1)
        return first < last ? first ..< last : first ..< first
    }

    /// Height of a document of `rowCount` rows, with the same margin below.
    func documentHeight(rowCount: Int) -> CGFloat { topInset * 2 + CGFloat(rowCount) * lineHeight }

    /// Width of the line-number gutter for numbers up to `maxNumber`.
    func gutterWidth(maxNumber: Int) -> CGFloat {
        let digits = max(2, String(max(maxNumber, 1)).count)
        let digitWidth = "8".size(withAttributes: [.font: numberFont]).width
        return ceil(CGFloat(digits) * digitWidth + 20)
    }
}
