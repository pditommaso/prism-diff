// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import CoreGraphics
import DiffCore
import Foundation

/// A colour written as "#RRGGBB" or "#RRGGBBAA" in theme files.
struct ThemeColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(red: Double(rgba >> 24 & 0xFF) / 255, green: Double(rgba >> 16 & 0xFF) / 255,
                  blue: Double(rgba >> 8 & 0xFF) / 255, alpha: Double(rgba & 0xFF) / 255)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = ThemeColor(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad colour '\(text)'")
        }
        self = color
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    var hex: String {
        func byte(_ v: Double) -> String {
            let text = String(Int((v * 255).rounded()), radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Colours of one kind of difference (insert, delete or change).
struct DifferenceColors: Codable, Equatable, Sendable {
    /// Line background.
    var band: ThemeColor
    /// Spacer outline and divider marker.
    var border: ThemeColor
    /// Background of the changed words.
    var word: ThemeColor
    /// Line-number cell background.
    var gutter: ThemeColor
    /// The same four, for the selected difference.
    var selectedBand: ThemeColor
    var selectedWord: ThemeColor
    var selectedGutter: ThemeColor
    /// Line-number colour on `selectedGutter`.
    var selectedNumber: ThemeColor
}

/// A text-comparison colour theme, stored as JSON.
///
/// ```json
/// { "id": "multicolor-light", "name": "...", "dark": false,
///   "background": "#FFFFFF", "text": "#...", "equalText": "#...",
///   "invisible": "#...", "spacer": "#...", "gutterBackground": "#...",
///   "lineNumber": "#...", "gutterBorder": "#...", "divider": "#...",
///   "insert": { DifferenceColors }, "delete": { ... }, "change": { ... } }
/// ```
struct Theme: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var dark: Bool
    var background: ThemeColor
    /// Text of changed lines.
    var text: ThemeColor
    /// Text of unchanged lines (a little quieter).
    var equalText: ThemeColor
    /// Line-end marks on changed lines.
    var invisible: ThemeColor
    /// Fill of Blocks padding.
    var spacer: ThemeColor
    var gutterBackground: ThemeColor
    var lineNumber: ThemeColor
    var gutterBorder: ThemeColor
    /// The line between the two panes.
    var divider: ThemeColor
    var insert: DifferenceColors
    var delete: DifferenceColors
    var change: DifferenceColors

    /// Colours of a block, classified by its ranges.
    func colors(for block: DiffBlock) -> DifferenceColors? {
        if block.kind == .equal { return nil }
        if block.isInsert { return insert }
        if block.isDelete { return delete }
        return change
    }

    static func decode(_ json: String) throws -> Theme {
        try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
    }
}

/// Text-pane appearance choices from the preferences.
enum ThemeChoice {
    /// Picks one of the four built-in themes.
    static func theme(dark: Bool, singleColor: Bool) -> Theme {
        switch (dark, singleColor) {
        case (false, false): BuiltinThemes.multicolorLight
        case (true, false): BuiltinThemes.multicolorDark
        case (false, true): BuiltinThemes.singleLight
        case (true, true): BuiltinThemes.singleDark
        }
    }
}

/// A theme's colours as `CGColor`s, made once per theme change instead of
/// on every draw.
struct ThemePalette {
    /// Colours of one kind of difference.
    struct Difference {
        let band, border, word, gutter: CGColor
        let selectedBand, selectedWord, selectedGutter, selectedNumber: CGColor

        init(_ colors: DifferenceColors) {
            band = colors.band.cgColor
            border = colors.border.cgColor
            word = colors.word.cgColor
            gutter = colors.gutter.cgColor
            selectedBand = colors.selectedBand.cgColor
            selectedWord = colors.selectedWord.cgColor
            selectedGutter = colors.selectedGutter.cgColor
            selectedNumber = colors.selectedNumber.cgColor
        }
    }

    let background, text, equalText, invisible, spacer: CGColor
    let gutterBackground, lineNumber, gutterBorder, divider: CGColor
    let insert, delete, change: Difference
    /// Find: the veil over text that does not match, the box behind every
    /// match, its outline, and the pill behind the current match.
    let findMatch, findCurrent: CGColor
    private(set) var findDim, findMatchBorder: CGColor
    /// Background of selected text.
    let selection: CGColor

    init(_ theme: Theme) {
        background = theme.background.cgColor
        text = theme.text.cgColor
        equalText = theme.equalText.cgColor
        invisible = theme.invisible.cgColor
        spacer = theme.spacer.cgColor
        gutterBackground = theme.gutterBackground.cgColor
        lineNumber = theme.lineNumber.cgColor
        gutterBorder = theme.gutterBorder.cgColor
        divider = theme.divider.cgColor
        insert = Difference(theme.insert)
        delete = Difference(theme.delete)
        change = Difference(theme.change)
        if theme.dark {
            findDim = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)
            findMatch = CGColor(srgbRed: 0.32, green: 0.32, blue: 0.36, alpha: 1)
            findMatchBorder = CGColor(srgbRed: 0.6, green: 0.6, blue: 0.64, alpha: 1)
            selection = CGColor(srgbRed: 0.25, green: 0.4, blue: 0.65, alpha: 0.75)
        } else {
            findDim = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14)
            findMatch = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            findMatchBorder = CGColor(srgbRed: 0.62, green: 0.62, blue: 0.66, alpha: 1)
            selection = CGColor(srgbRed: 0.65, green: 0.8, blue: 1, alpha: 0.8)
        }
        findCurrent = CGColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1)
        if theme.isContrasted {
            // Increase Contrast: a heavier veil, and match outlines in the
            // text colour.
            findDim = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: theme.dark ? 0.5 : 0.24)
            findMatchBorder = theme.text.cgColor
        }
    }

    /// Colours of a block, classified by its ranges (nil when unchanged).
    func colors(for block: DiffBlock) -> Difference? {
        if block.kind == .equal { return nil }
        if block.isInsert { return insert }
        if block.isDelete { return delete }
        return change
    }
}
