// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

@testable import DiffCore
import Testing

/// Unicode word boundaries of the word tokenizer, and the in-line hunks
/// they give for non-Latin text.
@Suite struct WordBreakTests {

    /// The tokens of one line (no terminator), as strings.
    static func tokens(_ text: String) -> [String] {
        tokens(Array(text.utf8))
    }

    static func tokens(_ bytes: [UInt8]) -> [String] {
        var tokens = Tokens()
        bytes.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            _ = tokens.tokenizeLine(base, 0, p.count, line: 0, ws: 0, interner: Interner(expected: 16))
        }
        return (0 ..< tokens.count).map {
            String(decoding: bytes[tokens.start($0) ..< tokens.end($0)], as: UTF8.self)
        }
    }

    @Test func asciiIsUnchanged() {
        #expect(Self.tokens("let x_1 = foo(bar);  // ok") ==
                ["let", " ", "x_1", " ", "=", " ", "foo", "(", "bar", ")", ";", "  ", "/", "/", " ", "ok"])
    }

    @Test func lettersOfAnyScriptFormWords() {
        #expect(Self.tokens("café naïve") == ["café", " ", "naïve"])
        #expect(Self.tokens("Ελληνικά, Русский и 한국어") == ["Ελληνικά", ",", " ", "Русский", " ", "и", " ", "한국어"])
        #expect(Self.tokens("x٣٤y") == ["x٣٤y"])  // Arabic-Indic digits join a word
    }

    @Test func eachIdeographAndHiraganaIsAWord() {
        #expect(Self.tokens("日本語のテキスト。") == ["日", "本", "語", "の", "テキスト", "。"])
        #expect(Self.tokens("中文分词") == ["中", "文", "分", "词"])
        #expect(Self.tokens("カタカナー語") == ["カタカナー", "語"])
    }

    @Test func combiningMarksStayWithTheirBase() {
        #expect(Self.tokens("e\u{301}te\u{301}") == ["e\u{301}te\u{301}"])
        #expect(Self.tokens("-\u{301}x") == ["-\u{301}", "x"])
        #expect(Self.tokens("か\u{3099}き") == ["か\u{3099}", "き"])
    }

    @Test func emojiSequencesAreOneToken() {
        #expect(Self.tokens("a👍🏽b") == ["a", "👍🏽", "b"])
        #expect(Self.tokens("👨‍👩‍👧!") == ["👨‍👩‍👧", "!"])
        #expect(Self.tokens("❤️❤️") == ["❤️", "❤️"])
    }

    @Test func otherCharactersAndInvalidBytesAreSingleTokens() {
        #expect(Self.tokens("a\u{3000}b\u{A0}c") == ["a", "\u{3000}", "b", "\u{A0}", "c"])
        #expect(Self.tokens("«x»") == ["«", "x", "»"])
        let invalid = Self.tokens([0x61, 0xFF, 0xFE, 0x62, 0xE6, 0x97])
        #expect(invalid.count == 6)  // a, FF, FE, b, and the truncated E6 97 as two
        #expect(invalid.first == "a" && invalid[3] == "b")
    }

    @Test func tokensCoverEveryByte() {
        let samples = ["日本語 abc", "𠀋𠀋 x", "e\u{301}", "👨‍👩‍👧 family", "a\u{200D}b"]
        for sample in samples {
            #expect(Self.tokens(sample).joined() == sample)
        }
    }

    /// `isTokenBoundary` may miss boundaries but must never invent one.
    @Test func certainBoundariesAreRealBoundaries() {
        let samples = ["héllo wörld, 日本語のテキスト x_1", "a\u{301}.b  c", "ab--cd 👍🏽 ok", "カナ漢字kana"]
        for sample in samples {
            let bytes = Array(sample.utf8)
            var real = Set<Int>()
            var offset = 0
            for token in Self.tokens(bytes) {
                offset += token.utf8.count
                real.insert(offset)
            }
            for k in 1 ..< bytes.count where isTokenBoundary(bytes[k - 1], bytes[k]) {
                #expect(real.contains(k), "\(sample) at \(k)")
            }
        }
    }

    // MARK: in-line hunks

    @Test func cjkChangeHighlightsOnlyTheChangedCharacter() {
        let a = "今日は良い天気です。\n".bytes, b = "今日は悪い天気です。\n".bytes
        let result = TextDiff.diff(a, b)
        #expect(result.blocks.count == 1)
        let block = result.blocks[0]
        #expect(block.kind == .change)
        // "今日は" is 9 bytes; "良" and "悪" are 3 bytes each.
        #expect(block.words == [WordHunk(aLine: 0, bLine: 0, a: 9 ..< 12, b: 9 ..< 12)])
    }

    @Test func cjkInsertionInsideALine() {
        let a = "東京へ行く\n".bytes, b = "東京と大阪へ行く\n".bytes
        let result = TextDiff.diff(a, b)
        #expect(result.blocks.first?.words == [WordHunk(aLine: 0, bLine: 0, a: 6 ..< 6, b: 6 ..< 15)])
    }

    @Test func accentedWordsChangeAsWholeWords() {
        let a = "le café noir\n".bytes, b = "le thé noir\n".bytes
        let result = TextDiff.diff(a, b)
        #expect(result.blocks.first?.words == [WordHunk(aLine: 0, bLine: 0, a: 3 ..< 8, b: 3 ..< 7)])
    }
}
