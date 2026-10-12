// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Testing
import DiffCore

@Suite struct LineRangeTests {
    @Test func upperBoundIsLowerPlusCount() {
        let range = LineRange(lowerBound: 3, count: 4)
        #expect(range.upperBound == 7)
        #expect(!range.isEmpty)
    }

    @Test func emptyRangeContainsNothing() {
        let range = LineRange(lowerBound: 5, count: 0)
        #expect(range.isEmpty)
        #expect(!range.contains(5))
    }

    @Test(arguments: [(2, false), (3, true), (6, true), (7, false)])
    func containsIsHalfOpen(line: Int, expected: Bool) {
        #expect(LineRange(lowerBound: 3, count: 4).contains(line) == expected)
    }

    @Test func equalityAndHashing() {
        let a = LineRange(lowerBound: 1, count: 2)
        let b = LineRange(lowerBound: 1, count: 2)
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a != LineRange(lowerBound: 1, count: 3))
    }
}
