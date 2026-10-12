// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

@testable import DiffCore
import Testing

/// Line pairing scores equal runs by characters, not bytes.
@Suite struct PairingScoreTests {
    @Test func utf16LengthCountsCharacters() {
        for (text, units) in [("abc", 3), ("ééé", 3), ("日本", 2), ("😀", 2), ("a😀é", 4)] {
            let bytes = Array(text.utf8)
            let length = bytes.withUnsafeBufferPointer { utf16Length($0.baseAddress!, 0, $0.count) }
            #expect(length == units, "\(text)")
        }
    }

    @Test func longestRunInCharactersWins() {
        // A's only line shares "ééééé" (5 characters, 10 bytes) with B's
        // first line and "abcdefgh\n" (9 characters, 9 bytes) with B's
        // second. By characters the second pairing wins; by bytes it would
        // be the first.
        let a = "ééééé-abcdefgh\n".bytes
        let b = "ééééé+x\ny=abcdefgh\n".bytes
        let result = TextDiff.diff(a, b)
        #expect(result.blocks.map(\.kind) == [.insert, .change])
        #expect(result.blocks[0].b == 0 ..< 1)
        #expect(result.blocks[1].a == 0 ..< 1 && result.blocks[1].b == 1 ..< 2)
    }
}
