// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Testing
@testable import PrismTool

/// Side-by-side cells are laid out only up to the point where truncation is
/// decided.
@Suite struct SideBySideTruncationTests {
    let plain = Palette(enabled: false)
    let colored = Palette(enabled: true)

    @Test func longLinesAreCutWithAnEllipsis() {
        let line = Array(String(repeating: "日本語テキスト ", count: 10).utf8)
        let (text, cells) = DisplayText.render(line[...], highlights: [], width: 11, color: nil, palette: plain)
        #expect(text == "日本語テキ…")
        #expect(cells == 11)
    }

    @Test func exactFitIsNotCut() {
        let line = Array("ab日e\u{301}".utf8)  // 5 cells, the accent takes none
        let (text, cells) = DisplayText.render(line[...], highlights: [], width: 5, color: "", palette: plain)
        #expect(text == "ab日e\u{301}")
        #expect(cells == 5)
    }

    @Test func invalidBytesShowAsReplacementCharacters() {
        let (text, _) = DisplayText.render([0x61, 0xFF, 0x62][...], highlights: [], width: 10, color: "",
                                           palette: plain)
        #expect(text == "a\u{FFFD}b")
    }

    @Test func highlightsBeyondTheCutAreDropped() {
        let line = Array(("abcdefghij" + String(repeating: "x", count: 100) + "CHANGED").utf8)
        let changed = line.count - 7 ..< line.count
        let (text, cells) = DisplayText.render(line[...], highlights: [changed], width: 8,
                                               color: Palette.yellow, palette: colored)
        #expect(cells == 8)
        #expect(text.contains("abcdefg"))
        #expect(!text.contains("CHANGED"))
        #expect(!text.contains(Palette.reverse))
        #expect(text.hasSuffix("…" + Palette.reset))
    }

    @Test func multiMegabyteLineRendersQuickly() {
        let line = Array(String(repeating: "é", count: 3_000_000).utf8)
        let start = ContinuousClock.now
        for _ in 0 ..< 100 {
            _ = DisplayText.render(line[...], highlights: [0 ..< 2], width: 80, color: Palette.red, palette: colored)
        }
        // Laying out all 3M scalars 100 times would take many seconds.
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
