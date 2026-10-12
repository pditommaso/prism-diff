// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// What one row of a Blocks pane shows.
enum BlocksRow: Equatable, Sendable {
    /// Line `line` (0-based) of this side, part of block `block`.
    case line(Int, block: Int)
    /// Padding that keeps the panes aligned: this side has fewer lines than
    /// the other in block `block`. `top` and `bottom` mark the first and last
    /// padding row of that block.
    case spacer(block: Int, top: Bool, bottom: Bool)
    /// The row after the last block: the empty line that follows a final
    /// newline, numbered `lineNumber` (1-based), or nothing when the side
    /// does not end with a newline.
    case trailer(lineNumber: Int?)
}

/// Row geometry of the Blocks layout, shared by both panes.
///
/// Every block takes `max(a.count, b.count)` rows on both sides, so a line
/// and its counterpart always sit on the same row and the two panes have the
/// same height. Rows are integers; the view turns them into points with a
/// fixed line height, so alignment is exact by construction. All lookups
/// are O(log blocks).
struct BlocksLayout: Sendable {
    let blocks: [DiffBlock]
    /// First row of each block, plus the trailer row at the end.
    let blockStart: [Int]
    /// Indices into `blocks` of the differences, in order.
    let changes: [Int]
    /// Unchanged blocks that count as changes: differences that a merge
    /// resolved. They stay selectable and keep the numbering stable.
    let resolved: Set<Int>
    /// Whether each side shows the empty line after a final newline.
    let trailerLine: (a: Int?, b: Int?)

    /// - Parameters:
    ///   - blocks: the diff's blocks, ordered, covering both sides.
    ///   - lineCounts: number of lines of A and B.
    ///   - showsTrailer: per side, true when the text ends with a newline
    ///     (or is empty) and an empty last line is shown.
    ///   - resolved: indices of unchanged blocks to list as (resolved) changes.
    init(blocks: [DiffBlock], resolved: Set<Int> = [], lineCounts: (a: Int, b: Int),
         showsTrailer: (a: Bool, b: Bool)) {
        self.blocks = blocks
        self.resolved = resolved
        var starts = [Int]()
        starts.reserveCapacity(blocks.count + 1)
        var changes = [Int]()
        var row = 0
        for (index, block) in blocks.enumerated() {
            starts.append(row)
            row += max(block.a.count, block.b.count)
            if block.kind != .equal || resolved.contains(index) { changes.append(index) }
        }
        starts.append(row)
        blockStart = starts
        self.changes = changes
        trailerLine = (showsTrailer.a ? lineCounts.a + 1 : nil, showsTrailer.b ? lineCounts.b + 1 : nil)
    }

    /// Row of the trailer line, after every block.
    var trailerRow: Int { blockStart[blockStart.count - 1] }

    /// Total number of rows, trailer included.
    var rowCount: Int { trailerRow + 1 }

    /// Rows of block `index`.
    func rows(ofBlock index: Int) -> Range<Int> { blockStart[index] ..< blockStart[index + 1] }

    /// Rows of change `index` (an index into `changes`).
    func rows(ofChange index: Int) -> Range<Int> { rows(ofBlock: changes[index]) }

    /// The block that covers `row`, or nil for the trailer row (and beyond).
    func block(atRow row: Int) -> Int? {
        guard row >= 0, row < trailerRow else { return nil }
        // Last block whose start is <= row. Empty blocks cannot occur (each
        // has at least one line on some side), so the answer is unique.
        var low = 0, high = blocks.count - 1
        while low < high {
            let mid = (low + high + 1) >> 1
            if blockStart[mid] <= row { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The content of `row` on one side.
    func content(atRow row: Int, side: DiffSide) -> BlocksRow {
        guard let index = block(atRow: row) else {
            return .trailer(lineNumber: side == .a ? trailerLine.a : trailerLine.b)
        }
        let block = blocks[index]
        let range = side == .a ? block.a : block.b
        let offset = row - blockStart[index]
        if offset < range.count {
            return .line(range.lowerBound + offset, block: index)
        }
        let last = blockStart[index + 1] - blockStart[index] - 1
        return .spacer(block: index, top: offset == range.count, bottom: offset == last)
    }

    /// The block holding line `line` of one side.
    func block(ofLine line: Int, side: DiffSide) -> Int? {
        // Blocks are ordered on both sides: last block whose range starts at
        // or before the line and is not empty there.
        var low = 0, high = blocks.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) >> 1
            let range = side == .a ? blocks[mid].a : blocks[mid].b
            if range.lowerBound > line {
                high = mid - 1
            } else if range.upperBound <= line {
                low = mid + 1
            } else {
                found = mid
                break
            }
        }
        return found
    }

    /// The row of line `line` of one side.
    func row(ofLine line: Int, side: DiffSide) -> Int? {
        guard let index = block(ofLine: line, side: side) else { return nil }
        let range = side == .a ? blocks[index].a : blocks[index].b
        return blockStart[index] + (line - range.lowerBound)
    }

    /// The change (index into `changes`) that block `index` is, if any.
    func change(ofBlock index: Int) -> Int? {
        var low = 0, high = changes.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            if changes[mid] == index { return mid }
            if changes[mid] < index { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// The change covering `row`, if any.
    func change(atRow row: Int) -> Int? {
        guard let index = block(atRow: row) else { return nil }
        return change(ofBlock: index)
    }
}
