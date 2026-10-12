// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import CoreGraphics
import DiffCore

/// The three ways a two-way comparison can be laid out.
enum ViewMode: String, Sendable, CaseIterable {
    /// Two padded panes: every block takes the same height on both sides.
    case blocks
    /// Two unpadded panes joined by connector lines.
    case fluid
    /// One column: unchanged lines once, each change as A lines then B lines.
    case unified

    /// Position in the layout switcher and the View menu (⌘1 … ⌘3).
    var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// What one row of a pane shows.
enum PaneRow: Equatable, Sendable {
    /// Line `line` (0-based) of `side`, part of block `block`.
    case line(DiffSide, Int, block: Int)
    /// Blocks padding: this side has fewer lines than the other in `block`.
    /// `top` and `bottom` mark the first and last padding row of the block.
    case spacer(block: Int, top: Bool, bottom: Bool)
    /// The row after the last block: the empty line that follows a final
    /// newline (1-based numbers per side, nil when a side has no such line).
    case trailer(a: Int?, b: Int?)
}

/// The rows of one pane for one layout: an index over `BlocksLayout` that
/// maps rows to content and changes to rows. Rows are integers; their
/// heights live in `RowHeights`.
struct PaneRows: Sendable {
    enum Kind: Equatable, Sendable {
        case blocks(DiffSide)
        case fluid(DiffSide)
        case unified
    }

    let kind: Kind
    let layout: BlocksLayout
    let lineCounts: (a: Int, b: Int)
    /// Unified only: first row of every block, plus the trailer row.
    private let unifiedStart: [Int]

    init(kind: Kind, layout: BlocksLayout, lineCounts: (a: Int, b: Int)) {
        self.kind = kind
        self.layout = layout
        self.lineCounts = lineCounts
        if kind == .unified {
            var starts = [Int]()
            starts.reserveCapacity(layout.blocks.count + 1)
            var row = 0
            for block in layout.blocks {
                starts.append(row)
                row += block.isShownOnce ? block.a.count : block.a.count + block.b.count
            }
            starts.append(row)
            unifiedStart = starts
        } else {
            unifiedStart = []
        }
    }

    /// Number of rows, trailer included.
    var count: Int { trailerRow + 1 }

    /// Row of the trailer line.
    var trailerRow: Int {
        switch kind {
        case .blocks: layout.trailerRow
        case let .fluid(side): side == .a ? lineCounts.a : lineCounts.b
        case .unified: unifiedStart[unifiedStart.count - 1]
        }
    }

    private var trailer: PaneRow { .trailer(a: layout.trailerLine.a, b: layout.trailerLine.b) }

    /// What `row` shows.
    func content(_ row: Int) -> PaneRow {
        switch kind {
        case let .blocks(side):
            switch layout.content(atRow: row, side: side) {
            case let .line(line, block): return .line(side, line, block: block)
            case let .spacer(block, top, bottom): return .spacer(block: block, top: top, bottom: bottom)
            case .trailer: return trailer
            }
        case let .fluid(side):
            guard row >= 0, row < trailerRow, let block = layout.block(ofLine: row, side: side) else { return trailer }
            return .line(side, row, block: block)
        case .unified:
            guard let block = block(atRow: row) else { return trailer }
            let range = layout.blocks[block]
            let offset = row - unifiedStart[block]
            if offset < range.a.count { return .line(.a, range.a.lowerBound + offset, block: block) }
            return .line(.b, range.b.lowerBound + offset - range.a.count, block: block)
        }
    }

    /// The block covering `row`, or nil for the trailer row.
    func block(atRow row: Int) -> Int? {
        guard row >= 0, row < trailerRow else { return nil }
        switch kind {
        case .blocks:
            return layout.block(atRow: row)
        case let .fluid(side):
            return layout.block(ofLine: row, side: side)
        case .unified:
            var low = 0, high = layout.blocks.count - 1
            while low < high {
                let mid = (low + high + 1) >> 1
                if unifiedStart[mid] <= row { low = mid } else { high = mid - 1 }
            }
            return low
        }
    }

    /// Rows of block `index`. In Fluid an empty side gives an empty range
    /// at the insertion point.
    func rows(ofBlock index: Int) -> Range<Int> {
        switch kind {
        case .blocks: layout.rows(ofBlock: index)
        case let .fluid(side): side == .a ? layout.blocks[index].a : layout.blocks[index].b
        case .unified: unifiedStart[index] ..< unifiedStart[index + 1]
        }
    }

    /// Rows of change `index` (an index into `layout.changes`).
    func rows(ofChange index: Int) -> Range<Int> { rows(ofBlock: layout.changes[index]) }

    /// The change covering `row`, if any.
    func change(atRow row: Int) -> Int? {
        block(atRow: row).flatMap { layout.change(ofBlock: $0) }
    }

    /// The row showing line `line` of `side`, if this pane shows that side.
    func row(ofLine line: Int, side: DiffSide) -> Int? {
        switch kind {
        case let .blocks(own):
            return own == side ? layout.row(ofLine: line, side: side) : nil
        case let .fluid(own):
            return own == side && line >= 0 && line < trailerRow ? line : nil
        case .unified:
            guard let block = layout.block(ofLine: line, side: side) else { return nil }
            let range = layout.blocks[block]
            if range.isShownOnce {
                // Unchanged lines are shown once, as their A line.
                let offset = line - (side == .a ? range.a.lowerBound : range.b.lowerBound)
                return unifiedStart[block] + offset
            }
            return side == .a ? unifiedStart[block] + line - range.a.lowerBound
                              : unifiedStart[block] + range.a.count + line - range.b.lowerBound
        }
    }

    /// Line numbers shown next to `row`: the line's own number and, in
    /// Unified, the counterpart of an unchanged line on the other side.
    func numbers(ofRow row: Int) -> (a: Int?, b: Int?) {
        switch content(row) {
        case let .line(side, line, block):
            let range = layout.blocks[block]
            if kind == .unified, range.isShownOnce {
                let offset = line - range.a.lowerBound
                return (line + 1, range.b.lowerBound + offset + 1)
            }
            return side == .a ? (line + 1, nil) : (nil, line + 1)
        case .spacer:
            return (nil, nil)
        case let .trailer(a, b):
            return (a, b)
        }
    }
}

/// Row geometry of one pane in points: rows, their heights and the font
/// metrics.
struct PaneGeometry {
    let rows: PaneRows
    let heights: RowHeights
    let metrics: TextMetrics

    var lineHeight: CGFloat { metrics.lineHeight }

    /// Top of `row`.
    func y(ofRow row: Int) -> CGFloat {
        metrics.topInset + CGFloat(heights.top(row)) * metrics.lineHeight
    }

    /// Height of `row` in points.
    func height(ofRow row: Int) -> CGFloat { CGFloat(heights.height(row)) * metrics.lineHeight }

    /// The row at `y` (may be negative or past the end; callers clamp).
    func row(atY y: CGFloat) -> Int {
        heights.row(atLine: Int(floor((y - metrics.topInset) / metrics.lineHeight)))
    }

    /// Rows that intersect `minY ..< maxY`, clamped to the pane.
    func rows(in minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        let first = max(0, row(atY: minY))
        let last = min(rows.count, row(atY: maxY) + 1)
        return first < last ? first ..< last : first ..< first
    }

    /// Height of the document, with a margin above and below.
    var documentHeight: CGFloat { metrics.topInset * 2 + CGFloat(heights.total) * metrics.lineHeight }
}

extension DiffBlock {
    /// Unified shows the block's lines once (as its A lines): unchanged
    /// text. A resolved Keep Both block, whose sides differ in length,
    /// shows both sides.
    var isShownOnce: Bool { kind == .equal && a.count == b.count }
}
