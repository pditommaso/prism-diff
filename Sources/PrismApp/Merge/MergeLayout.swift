// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation

/// What the merge view draws: the lines of A, B and the result, region by
/// region, with the word differences of A and B. Built from a
/// `MergeSession` after every change.
struct MergeDisplay: Equatable {
    enum Kind: Equatable {
        /// A and B agree.
        case equal
        /// Only one side changed; it was taken automatically.
        case auto
        /// Both sides changed.
        case conflict
    }

    /// The shape of a region's difference, for the colours of a region
    /// that is not a conflict (as in a two-way comparison).
    enum Shape: Equatable {
        case change, insert, delete
    }

    struct Region: Equatable {
        var kind: Kind
        var shape: Shape
        /// A conflict that has a choice or an edit (always false otherwise).
        var resolved: Bool
        /// Lines of A and of B.
        var a: Range<Int>
        var b: Range<Int>
        /// The result's lines for this region: an unresolved conflict shows
        /// one empty placeholder line instead.
        var output: [String]
        var placeholder: Bool
        /// Number (0-based) of the region's first line in the saved result.
        var outputStart: Int
    }

    var linesA: [String] = []
    var linesB: [String] = []
    var regions: [Region] = []
    /// UTF-16 ranges of the word differences on changed lines of A and B.
    var wordsA: [Int: [Range<Int>]] = [:]
    var wordsB: [Int: [Range<Int>]] = [:]
    var unresolvedCount = 0
    var conflictCount = 0

    /// The text of every line of `bytes`, terminators removed.
    static func lines(_ bytes: [UInt8], _ index: LineIndex) -> [String] {
        (0 ..< index.count).map { i in
            var range = index.range(i)
            if range.upperBound > range.lowerBound, bytes[range.upperBound - 1] == 0x0A {
                range = range.lowerBound ..< range.upperBound - 1
            }
            if range.upperBound > range.lowerBound, bytes[range.upperBound - 1] == 0x0D {
                range = range.lowerBound ..< range.upperBound - 1
            }
            return String(decoding: bytes[range], as: UTF8.self)
        }
    }

    /// The text of every line of `bytes` (LF, CRLF or CR line ends).
    static func lines(_ bytes: [UInt8]) -> [String] {
        let starts = LineText.starts(bytes)
        return (0 ..< starts.count - 1).map { i in
            var end = starts[i + 1]
            if end > starts[i], bytes[end - 1] == 0x0A { end -= 1 }
            if end > starts[i], bytes[end - 1] == 0x0D { end -= 1 }
            return String(decoding: bytes[starts[i] ..< end], as: UTF8.self)
        }
    }

    /// Byte columns of a line converted to UTF-16 offsets.
    static func utf16Range(_ bytes: [UInt8], lineStart: Int, lineEnd: Int, _ columns: Range<Int>) -> Range<Int> {
        func offset(_ column: Int) -> Int {
            let end = min(lineStart + column, lineEnd)
            return String(decoding: bytes[lineStart ..< max(lineStart, end)], as: UTF8.self).utf16.count
        }
        return offset(columns.lowerBound) ..< offset(columns.upperBound)
    }

    @MainActor
    init(session: MergeSession) {
        guard let result = session.result else { return }
        let linesA = result.diffAB.linesA, linesB = result.diffAB.linesB
        self.linesA = Self.lines(result.a, linesA)
        self.linesB = Self.lines(result.b, linesB)
        for block in result.diffAB.blocks {
            for hunk in block.words {
                let rangeA = linesA.range(hunk.aLine), rangeB = linesB.range(hunk.bLine)
                wordsA[hunk.aLine, default: []].append(
                    Self.utf16Range(result.a, lineStart: rangeA.lowerBound, lineEnd: rangeA.upperBound, hunk.a))
                wordsB[hunk.bLine, default: []].append(
                    Self.utf16Range(result.b, lineStart: rangeB.lowerBound, lineEnd: rangeB.upperBound, hunk.b))
            }
        }
        var start = 0
        for (index, region) in result.regions.enumerated() {
            let kind: Kind = switch region.kind {
            case .equal: .equal
            case .auto: .auto
            case .conflict: .conflict
            }
            let shape: Shape = region.aRange.isEmpty ? .insert : region.bRange.isEmpty ? .delete : .change
            let output = session.output(ofRegion: index)
            let lines = output.placeholder ? [""] : Self.lines(output.bytes)
            regions.append(Region(kind: kind, shape: shape, resolved: kind == .conflict && !output.placeholder,
                                  a: region.aRange, b: region.bRange, output: lines,
                                  placeholder: output.placeholder, outputStart: start))
            start += output.placeholder ? region.aRange.count : lines.count
        }
        unresolvedCount = session.unresolvedCount
        conflictCount = session.conflicts.count
    }

    init() {}
}

/// Which text a row of the merge view shows.
enum MergeSource: Equatable {
    case a, b, output
}

/// One row of a column of the merge view.
struct MergeRow: Equatable {
    enum Content: Equatable {
        /// Line `line` of `source` (0-based). `number` and `numberB` are the
        /// 1-based numbers shown in the gutter (the unified column shows A's
        /// and B's numbers side by side).
        case line(MergeSource, Int, number: Int?, numberB: Int?)
        /// The empty line that stands for an unresolved conflict.
        case placeholder(number: Int)
        /// Padding: this column has fewer lines than the region's height.
        case filler
    }

    var content: Content
    /// The region the row belongs to.
    var region: Int
}

/// The rows of the merge view's columns for one layout, and where each
/// region lies in each column.
struct MergeLayout: Equatable {
    /// Columns left to right: A, result, B (Blocks and Fluid), or the
    /// interleaved A/B column and the result (Unified).
    var columns: [[MergeRow]]
    /// Per column, the rows of each region.
    var spans: [[Range<Int>]]
    let mode: ViewMode

    /// The column that shows the result.
    let outputColumn = 1

    var rowCount: Int { columns.map(\.count).max() ?? 0 }

    init(_ display: MergeDisplay, mode: ViewMode) {
        self.mode = mode
        let count = mode == .unified ? 2 : 3
        columns = Array(repeating: [], count: count)
        spans = Array(repeating: [], count: count)

        func outputRows(_ region: MergeDisplay.Region, _ index: Int) -> [MergeRow] {
            if region.placeholder {
                return [MergeRow(content: .placeholder(number: region.outputStart + 1), region: index)]
            }
            return region.output.indices.map { k in
                MergeRow(content: .line(.output, region.outputStart + k, number: region.outputStart + k + 1, numberB: nil),
                         region: index)
            }
        }
        func sideRows(_ source: MergeSource, _ range: Range<Int>, _ index: Int) -> [MergeRow] {
            range.map { MergeRow(content: .line(source, $0, number: $0 + 1, numberB: nil), region: index) }
        }

        for (index, region) in display.regions.enumerated() {
            var parts: [[MergeRow]]
            switch mode {
            case .blocks, .fluid:
                parts = [sideRows(.a, region.a, index), outputRows(region, index), sideRows(.b, region.b, index)]
            case .unified:
                if region.kind == .equal {
                    parts = [zip(region.a, region.b).map { a, b in
                        MergeRow(content: .line(.a, a, number: a + 1, numberB: b + 1), region: index)
                    }, outputRows(region, index)]
                } else {
                    let interleaved = region.a.map {
                        MergeRow(content: .line(.a, $0, number: $0 + 1, numberB: nil), region: index)
                    } + region.b.map {
                        MergeRow(content: .line(.b, $0, number: nil, numberB: $0 + 1), region: index)
                    }
                    parts = [interleaved, outputRows(region, index)]
                }
            }
            if mode == .blocks {
                // Every column takes the region's full height (Fluid and
                // Unified let each column run on).
                let height = parts.map(\.count).max() ?? 0
                for k in parts.indices where parts[k].count < height {
                    parts[k] += Array(repeating: MergeRow(content: .filler, region: index), count: height - parts[k].count)
                }
            }
            for k in parts.indices {
                let start = columns[k].count
                columns[k] += parts[k]
                spans[k].append(start ..< columns[k].count)
            }
        }
    }
}
