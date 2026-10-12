// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

/// A half-open run of lines: `count` lines starting at `lowerBound` (0-based).
/// Immutable, so the non-negative bounds checked by `init` always hold.
public struct LineRange: Hashable, Sendable {
    public let lowerBound: Int
    public let count: Int

    public init(lowerBound: Int, count: Int) {
        precondition(lowerBound >= 0, "lowerBound must not be negative")
        precondition(count >= 0, "count must not be negative")
        self.lowerBound = lowerBound
        self.count = count
    }

    /// One past the last line in the range.
    public var upperBound: Int { lowerBound + count }

    public var isEmpty: Bool { count == 0 }

    public func contains(_ line: Int) -> Bool {
        line >= lowerBound && line < upperBound
    }
}
