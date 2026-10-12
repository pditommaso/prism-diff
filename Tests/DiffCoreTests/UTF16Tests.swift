// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation
import Testing

@Suite struct UTF16Tests {
    /// Reference: the UTF-16 length of the bytes decoded with replacement.
    static func reference(_ bytes: [UInt8]) -> Int {
        String(decoding: bytes, as: UTF8.self).utf16.count
    }

    static let samples: [(String, [UInt8])] = [
        ("ascii", Array("hello, world".utf8)),
        ("2-byte", Array("café crème".utf8)),
        ("3-byte", Array("漢字かな交じり".utf8)),
        ("4-byte", Array("a😀b🎉c".utf8)),
        ("mixed", Array("é漢😀x".utf8)),
        ("stray continuation", [0x61, 0x80, 0x62, 0xBF, 0xBF]),
        ("bad leads", [0xC0, 0xAF, 0xC1, 0xF5, 0xFF, 0x41]),
        ("truncated 3-byte", [0xE6, 0xBC, 0x41]),
        ("truncated 4-byte", [0xF0, 0x9F, 0x98, 0x41, 0xF0, 0x9F]),
        ("surrogate", [0xED, 0xA0, 0x80, 0x41]),
        ("overlong", [0xE0, 0x80, 0xAF, 0xF0, 0x80, 0x80, 0x80]),
        ("above U+10FFFF", [0xF4, 0x90, 0x80, 0x80, 0xF4, 0x8F, 0xBF, 0xBF]),
        ("lead at end", [0x41, 0xC3]),
    ]

    @Test func countsEqualFoundationOnEveryPrefixAndSlice() {
        for (name, bytes) in Self.samples {
            #expect(UTF16Columns.count(bytes, from: 0, to: bytes.count) == Self.reference(bytes), "\(name)")
            for start in 0 ... bytes.count {
                for end in start ... bytes.count {
                    let expected = Self.reference(Array(bytes[start ..< end]))
                    #expect(UTF16Columns.count(bytes, from: start, to: end) == expected,
                            "\(name) [\(start), \(end))")
                }
            }
        }
    }

    @Test func emojiIsASurrogatePair() {
        let bytes = Array("😀".utf8)
        #expect(bytes.count == 4)
        #expect(UTF16Columns.count(bytes, from: 0, to: 4) == 2)
    }

    /// Checks one hunk side against Foundation: the UTF-16 column of a byte
    /// column is the UTF-16 length of the line's bytes up to it.
    static func check(_ result: TextDiffResult, _ hunk: WordHunk, _ side: DiffSide, _ buffer: [UInt8]) -> Bool {
        let line = side == .a ? hunk.aLine : hunk.bLine
        let columns = side == .a ? hunk.a : hunk.b
        let start = result.lines(side).range(line).lowerBound
        let lower = reference(Array(buffer[start ..< start + columns.lowerBound]))
        let upper = reference(Array(buffer[start ..< start + columns.upperBound]))
        return result.utf16Range(of: hunk, side: side, in: buffer) == lower ..< upper
    }

    @Test(arguments: [
        ("let name = \"x\"\n", "let name = \"y\"\n"),
        ("café au lait\n", "café noir\n"),
        ("価格は百円です\n", "価格は二百円です\n"),
        ("say 😀 hi\n", "say 🎉🎉 hi\n"),
        ("pre é 漢 😀 post\n", "pre é 字 😀 changed\n"),
    ])
    func hunkRangesMatchFoundation(a: String, b: String) {
        let ba = Array(a.utf8), bb = Array(b.utf8)
        let result = TextDiff.diff(ba, bb)
        let hunks = result.blocks.flatMap(\.words)
        #expect(!hunks.isEmpty)
        for hunk in hunks {
            #expect(Self.check(result, hunk, .a, ba))
            #expect(Self.check(result, hunk, .b, bb))
        }
    }

    @Test func emojiHunkCoversTwoUnitsPerScalar() {
        let a = Array("say 😀 hi\n".utf8), b = Array("say 🎉🎉 hi\n".utf8)
        let result = TextDiff.diff(a, b)
        let hunk = result.blocks.flatMap(\.words)[0]
        #expect(hunk.a == 4 ..< 8 && hunk.b == 4 ..< 12)
        #expect(result.utf16Range(of: hunk, side: .a, in: a) == 4 ..< 6)
        #expect(result.utf16Range(of: hunk, side: .b, in: b) == 4 ..< 8)
    }

    @Test func invalidBytesInAHunk() {
        let a: [UInt8] = Array("key = ".utf8) + [0xFF, 0xC3] + Array(" end\n".utf8)
        let b: [UInt8] = Array("key = ".utf8) + [0xE2, 0x82] + Array(" end\n".utf8)
        let result = TextDiff.diff(a, b)
        let hunks = result.blocks.flatMap(\.words)
        #expect(!hunks.isEmpty)
        for hunk in hunks {
            #expect(Self.check(result, hunk, .a, a))
            #expect(Self.check(result, hunk, .b, b))
        }
    }

    @Test func lineStartsMatchFoundation() {
        let bytes = Array("é\n漢字\n😀😀\n".utf8) + [0xFF, 0x80, 0xE2] + Array("x\nend".utf8)
        let result = TextDiff.diff(bytes, Array("other\n".utf8))
        for line in 0 ... result.linesA.count {
            let offset = Int(result.linesA.starts[line])
            #expect(result.utf16LineStart(line, side: .a, in: bytes) == Self.reference(Array(bytes[..<offset])))
        }
    }
}
