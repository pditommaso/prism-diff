// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

/// Heights of the rows of a pane, in visual lines, with O(1) row → offset
/// and O(log n) offset → row lookups.
///
/// Without wrapping every row is one visual line tall and no table is kept.
/// With wrapping a row can span several visual lines; a prefix-sum table
/// holds the first visual line of every row. Heights are whole visual
/// lines, so a row's position in points is an integer multiple of the line
/// height: two panes that share a table can never drift apart.
struct RowHeights: Sendable, Equatable {
    /// Number of rows.
    let count: Int
    /// `prefix[r]` is the first visual line of row `r`; `prefix[count]` is
    /// the total. Nil when every row is one line tall.
    private let prefix: [Int32]?

    /// Every row one visual line tall.
    init(uniform count: Int) {
        self.count = count
        prefix = nil
    }

    /// Rows with the given heights (each at least 1).
    init<Heights: Sequence>(_ heights: Heights) where Heights.Element == Int {
        var table: [Int32] = [0]
        table.reserveCapacity(heights.underestimatedCount + 1)
        var total: Int32 = 0
        var tall = false
        for height in heights {
            let h = Int32(max(height, 1))
            if h > 1 { tall = true }
            total &+= h
            table.append(total)
        }
        count = table.count - 1
        prefix = tall ? table : nil
    }

    /// True when some row is taller than one line.
    var isUniform: Bool { prefix == nil }

    /// Total number of visual lines.
    var total: Int { prefix.map { Int($0[count]) } ?? count }

    /// First visual line of `row` (rows past the end continue the count).
    func top(_ row: Int) -> Int {
        guard let prefix else { return row }
        if row <= 0 { return row }
        if row >= count { return Int(prefix[count]) + (row - count) }
        return Int(prefix[row])
    }

    /// Height of `row` in visual lines.
    func height(_ row: Int) -> Int {
        guard let prefix, row >= 0, row < count else { return 1 }
        return Int(prefix[row + 1] - prefix[row])
    }

    /// The row that holds visual line `line` (may be negative or past the
    /// end, like `top`).
    func row(atLine line: Int) -> Int {
        guard let prefix else { return line }
        if line < 0 { return line }
        let total = Int(prefix[count])
        if line >= total { return count + (line - total) }
        // Last row whose first line is <= line.
        var low = 0, high = count - 1
        let target = Int32(line)
        while low < high {
            let mid = (low + high + 1) >> 1
            if prefix[mid] <= target { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
