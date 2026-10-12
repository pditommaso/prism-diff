// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Dispatch

// Three-way merge.
//
// Three two-way diffs are computed: A-B, base-A and base-B. The regions are
// built in base coordinates, from the two base diffs alone: their edits are
// walked together in base order, and edits of A and B that overlap in base
// are grouped into one chunk (see `Chunk` for what overlapping means). A
// chunk with edits of one side only takes that side automatically; a chunk
// with edits of both is a conflict, unless both made the same edit. Between
// chunks the three files are in step and A and B are equal. This way an
// ambiguous placement of a repeated line in one diff can never make an
// untouched side look changed, or hide a real edit.
//
// A chunk that both sides edited is then split where A and B agree: lines
// that are equal in A and B and stand for the same base line on both sides
// cut it into smaller pairs of differing lines, and each pair is decided on
// its own, by content (only A differs from base there, only B, or both).
// So two sides that rewrote neighbouring lines, agreeing on the lines in
// between, give automatic choices instead of one big conflict.
//
// The merged text is A with every automatic choice applied: an unresolved
// conflict keeps A's lines (views show it as an empty placeholder until it
// is resolved).

/// What the merged text takes from a region. The raw values are stable codes
/// 0-4, so they can be persisted and exchanged.
public enum MergeChoice: Int, Sendable, CaseIterable, Hashable {
    /// No choice: an unresolved conflict, which keeps A's lines in the
    /// merged text, or an automatic region whose choice was reset, which
    /// takes nothing.
    case none = 0
    /// A's lines.
    case a = 1
    /// B's lines.
    case b = 2
    /// A's lines followed by B's.
    case aThenB = 3
    /// B's lines followed by A's.
    case bThenA = 4

    /// The name used in JSON output: none, a, b, aThenB, bThenA.
    public var name: String {
        switch self {
        case .none: "none"
        case .a: "a"
        case .b: "b"
        case .aThenB: "aThenB"
        case .bThenA: "bThenA"
        }
    }
}

/// How a merge region came about.
public enum MergeRegionKind: String, Sendable, CaseIterable, Hashable {
    /// A and B agree (under the whitespace mode in effect). The merged text
    /// takes A's bytes.
    case equal
    /// A and B differ but only one of them changed relative to base, so that
    /// side was chosen automatically.
    case auto
    /// Both sides changed relative to base: a conflict. It starts unresolved
    /// (choice `.none`, A's lines in the merged text);
    /// `Merge3Result.applying(choice:to:)` resolves it.
    case conflict
}

/// One region of a three-way merge. All ranges are 0-based, half-open line
/// ranges. The regions of a result are ordered and together cover A, B and
/// the merged text exactly once.
public struct MergeRegion: Sendable, Equatable, Hashable {
    public var kind: MergeRegionKind
    /// What the merged text currently takes. Always `.none` for `.equal`
    /// regions, whose merged lines are A's.
    public var choice: MergeChoice
    /// The choice made by the automatic merge: the changed side for `.auto`,
    /// `.none` for `.conflict` and `.equal`.
    public var autoChoice: MergeChoice
    /// Lines of A.
    public var aRange: Range<Int>
    /// Lines of B.
    public var bRange: Range<Int>
    /// Lines of base. Both `aRange` and `bRange` replace exactly these base
    /// lines (an empty range is an insertion point).
    public var baseRange: Range<Int>
    /// Lines of the merged text produced by this region.
    public var mergedRange: Range<Int>

    public init(kind: MergeRegionKind, choice: MergeChoice, autoChoice: MergeChoice,
                aRange: Range<Int>, bRange: Range<Int>, baseRange: Range<Int>,
                mergedRange: Range<Int>) {
        self.kind = kind
        self.choice = choice
        self.autoChoice = autoChoice
        self.aRange = aRange
        self.bRange = bRange
        self.baseRange = baseRange
        self.mergedRange = mergedRange
    }

    /// True when the merge found a conflict here, whatever the current choice.
    public var isConflict: Bool { kind == .conflict }

    /// True for a conflict that has no choice yet.
    public var isUnresolved: Bool { kind == .conflict && choice == .none }
}

/// The outcome of a three-way merge.
///
/// The value keeps the three inputs (arrays are copy-on-write, so this costs
/// no copy) so that `applying(choice:to:)` can rebuild the merged text.
public struct Merge3Result: Sendable, Equatable {
    public var regions: [MergeRegion]
    /// The merged text: A's equal lines plus each region's chosen lines; an
    /// unresolved conflict contributes A's lines.
    public private(set) var merged: [UInt8]
    /// Line index of `merged`.
    public private(set) var mergedLines: LineIndex
    /// Regions that started as conflicts.
    public private(set) var conflictCount: Int
    /// Conflicts that still have no choice.
    public private(set) var unresolvedConflictCount: Int

    public let base: [UInt8]
    public let a: [UInt8]
    public let b: [UInt8]
    /// The A-B diff (with word hunks), for display. Regions do not follow
    /// its blocks.
    public let diffAB: TextDiffResult
    /// The base-A diff (line level only).
    public let diffBaseA: TextDiffResult
    /// The base-B diff (line level only).
    public let diffBaseB: TextDiffResult
    /// The whitespace mode the three diffs used.
    public let whitespace: WhitespaceMode

    init(regions: [MergeRegion], base: [UInt8], a: [UInt8], b: [UInt8],
         diffAB: TextDiffResult, diffBaseA: TextDiffResult, diffBaseB: TextDiffResult,
         whitespace: WhitespaceMode) {
        self.regions = regions
        self.base = base
        self.a = a
        self.b = b
        self.diffAB = diffAB
        self.diffBaseA = diffBaseA
        self.diffBaseB = diffBaseB
        self.whitespace = whitespace
        self.merged = []
        self.mergedLines = LineIndex(starts: [0])
        self.conflictCount = 0
        self.unresolvedConflictCount = 0
        rebuild()
    }

    /// The regions where A and B differ.
    public var differences: [MergeRegion] { regions.filter { $0.kind != .equal } }

    /// A copy with `choice` applied to region `index`, the merged text and
    /// every region's `mergedRange` recomputed, and the unresolved count
    /// updated. Choosing `.none` for a conflict makes it unresolved again
    /// (A's lines); for an automatic region it takes nothing.
    /// `index` must name a region that is not `.equal`.
    public func applying(choice: MergeChoice, to index: Int) -> Merge3Result {
        precondition(regions.indices.contains(index), "no merge region \(index)")
        precondition(regions[index].kind != .equal, "equal regions have no choice")
        var copy = self
        copy.regions[index].choice = choice
        copy.rebuild()
        return copy
    }

    /// Recomputes `merged`, `mergedLines`, every `mergedRange` and the counts
    /// from the regions' choices.
    private mutating func rebuild() {
        let linesA = diffAB.linesA, linesB = diffAB.linesB
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var line = 0

        func append(_ bytes: [UInt8], _ index: LineIndex, _ range: Range<Int>) {
            guard !range.isEmpty else { return }
            // Only the last line of a file can lack a terminator. If such a
            // line is followed by more text (for example A then B), end it
            // with LF so the two do not run together.
            if let last = out.last, last != lineFeed && last != carriageReturn {
                out.append(lineFeed)
            }
            out.append(contentsOf: bytes[index.range(range.lowerBound).lowerBound ..< index.range(range.upperBound - 1).upperBound])
            line += range.count
        }

        var conflicts = 0, unresolved = 0
        for i in regions.indices {
            let start = line
            let region = regions[i]
            switch region.kind == .equal || region.isUnresolved ? MergeChoice.a : region.choice {
            case .none: break
            case .a: append(a, linesA, region.aRange)
            case .b: append(b, linesB, region.bRange)
            case .aThenB:
                append(a, linesA, region.aRange)
                append(b, linesB, region.bRange)
            case .bThenA:
                append(b, linesB, region.bRange)
                append(a, linesA, region.aRange)
            }
            regions[i].mergedRange = start ..< line
            if region.kind == .conflict {
                conflicts += 1
                if region.choice == .none { unresolved += 1 }
            }
        }
        merged = out
        mergedLines = LineIndex(starts: out.withUnsafeBufferPointer { splitLines($0) })
        conflictCount = conflicts
        unresolvedConflictCount = unresolved
    }
}

/// Three-way text merge.
public enum Merge3 {

    /// Merges A and B, which both descend from `base`.
    ///
    /// The three diffs use `options` (whitespace mode, heuristics,
    /// cancellation); the base diffs skip word refinement, which the merge
    /// does not need. They run concurrently when `options.parallel` is set
    /// and the inputs are big enough to pay for it. Throws
    /// `DiffError.cancelled` when `options.cancellation` is cancelled.
    ///
    /// Throws `DiffError.tooLarge` when base reaches 2 GiB, or A and B
    /// together do: the merged text can hold all of A and all of B (every
    /// conflict resolved as `.aThenB`), and texts of 2 GiB or more are not
    /// supported.
    ///
    /// Both base diffs have base on the left, so that the engine breaks ties
    /// between equally good alignments the same way for A and for B: when
    /// A and B are equal, their edit lists are identical and every chunk is
    /// the same edit on both sides.
    public static func merge(base: [UInt8], a: [UInt8], b: [UInt8],
                             options: DiffOptions = DiffOptions()) throws(DiffError) -> Merge3Result {
        try checkSize(base: base.count, a.count, b.count)
        var lineOnly = options
        lineOnly.wordRefinement = false
        let jobs: [(DiffOptions, [UInt8], [UInt8])] = [(options, a, b), (lineOnly, base, a), (lineOnly, base, b)]

        let box = DiffSlots()
        let total = base.count + a.count + b.count
        if options.parallel && total >= parallelMinBytes {
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let (opts, x, y) = jobs[i]
                box.put(i, Result { () throws(DiffError) in try TextDiff.cancellableDiff(x, y, options: opts) })
            }
        } else {
            for i in jobs.indices {
                let (opts, x, y) = jobs[i]
                box.put(i, Result { () throws(DiffError) in try TextDiff.cancellableDiff(x, y, options: opts) })
            }
        }
        let ab = try box.get(0), baseA = try box.get(1), baseB = try box.get(2)
        if options.cancellation.isCancelled { throw .cancelled }

        let editsA = sideEdits(baseA, base, a), editsB = sideEdits(baseB, base, b)
        var builder = RegionBuilder()
        var i = 0, j = 0
        while i < editsA.count || j < editsB.count {
            // One chunk: the next edit in base order, plus every following
            // edit that overlaps the other side's edits already in it.
            var chunk = Chunk()
            while true {
                let takeA: Bool
                if i == editsA.count {
                    takeA = false
                } else if j == editsB.count {
                    takeA = true
                } else {
                    let x = editsA[i].base, y = editsB[j].base
                    takeA = (x.lowerBound, x.upperBound) <= (y.lowerBound, y.upperBound)
                }
                if takeA && i == editsA.count || !takeA && j == editsB.count { break }
                let edit = takeA ? editsA[i] : editsB[j]
                if !chunk.isEmpty && !chunk.overlaps(edit.base, otherSideOf: takeA) { break }
                chunk.add(edit, fromA: takeA)
                if takeA { i += 1 } else { j += 1 }
            }
            builder.equal(upTo: chunk.base.lowerBound)
            let aRange = builder.a ..< builder.a + chunk.base.count + chunk.deltaA
            let bRange = builder.b ..< builder.b + chunk.base.count + chunk.deltaB
            let kind: MergeRegionKind
            let choice: MergeChoice
            switch (chunk.hasA, chunk.hasB) {
            case (true, false): (kind, choice) = (.auto, .a)
            case (false, true): (kind, choice) = (.auto, .b)
            default:
                let same = try sameLines(a, ab.linesA, aRange, b, ab.linesB, bRange, options: lineOnly)
                if same {
                    (kind, choice) = (.equal, .none)
                } else {
                    // Both sides edited: decide each A-B pair on its own.
                    let pieces = try refineConflict(base: base, baseA.linesA, chunk.base, a: a, ab.linesA, aRange,
                                                    b: b, ab.linesB, bRange, options: options)
                    for piece in pieces {
                        builder.append(kind: piece.kind, choice: piece.choice, aRange: piece.a, bRange: piece.b,
                                       base: piece.base)
                    }
                    continue
                }
            }
            builder.append(kind: kind, choice: choice, aRange: aRange, bRange: bRange, base: chunk.base)
        }
        builder.equal(upTo: baseA.linesA.count)
        precondition(builder.a == ab.linesA.count && builder.b == ab.linesB.count,
                     "merge regions do not cover A and B")
        if options.cancellation.isCancelled { throw .cancelled }
        return Merge3Result(regions: builder.regions, base: base, a: a, b: b,
                            diffAB: ab, diffBaseA: baseA, diffBaseB: baseB,
                            whitespace: options.whitespace)
    }

    /// One part of a conflict chunk after `refineConflict`.
    struct Piece: Equatable {
        var kind: MergeRegionKind
        var choice: MergeChoice
        var a: Range<Int>, b: Range<Int>, base: Range<Int>
    }

    /// Splits a chunk that both sides edited (A lines `aRange`, B lines
    /// `bRange`, base lines `baseRange`) into pieces, one per pair of
    /// differing A and B lines, and decides each by content.
    ///
    /// The cut points are anchor lines: an A line and a B line that are
    /// equal (in the A-B diff of the chunk) and stand for the same base line
    /// in both base diffs of the chunk, where a line stands for a base line
    /// when the two are equal or paired as a changed line. Anchors are equal
    /// regions (both sides made the same edit, or none). Between anchors a
    /// piece whose A lines are base's takes B, one whose B lines are base's
    /// takes A, and any other is a conflict. Without anchors the chunk stays
    /// one conflict. Where both sides inserted lines at the same base point
    /// (an empty `baseRange`, as when there is no base at all), the lines A
    /// and B have in common are the anchors. Ranges are absolute.
    static func refineConflict(base: [UInt8], _ linesBase: LineIndex, _ baseRange: Range<Int>,
                               a: [UInt8], _ linesA: LineIndex, _ aRange: Range<Int>,
                               b: [UInt8], _ linesB: LineIndex, _ bRange: Range<Int>,
                               options: DiffOptions) throws(DiffError) -> [Piece] {
        let whole = [Piece(kind: .conflict, choice: .none, a: aRange, b: bRange, base: baseRange)]
        guard !aRange.isEmpty, !bRange.isEmpty else { return whole }
        func bytes(_ text: [UInt8], _ index: LineIndex, _ range: Range<Int>) -> [UInt8] {
            range.isEmpty ? []
                : Array(text[index.range(range.lowerBound).lowerBound ..< index.range(range.upperBound - 1).upperBound])
        }
        let insertion = baseRange.isEmpty
        let o = bytes(base, linesBase, baseRange), x = bytes(a, linesA, aRange), y = bytes(b, linesB, bRange)
        var local = options
        local.parallel = false
        local.wordRefinement = true
        let ox = try TextDiff.cancellableDiff(o, x, options: local)
        let oy = try TextDiff.cancellableDiff(o, y, options: local)
        let xy = try TextDiff.cancellableDiff(x, y, options: local)

        /// Side line -> the base line it stands for (equal or paired).
        func baseLines(_ diff: TextDiffResult) -> [Int?] {
            var map = [Int?](repeating: nil, count: diff.linesB.count)
            for block in diff.blocks where block.kind == .equal || block.kind == .change {
                for k in 0 ..< min(block.a.count, block.b.count) { map[block.b.lowerBound + k] = block.a.lowerBound + k }
            }
            return map
        }
        let mapX = baseLines(ox), mapY = baseLines(oy)
        var anchors: [(x: Int, y: Int, o: Int)] = []
        for block in xy.blocks where block.kind == .equal {
            for k in 0 ..< block.a.count {
                let i = block.a.lowerBound + k, j = block.b.lowerBound + k
                if insertion {
                    // No base lines: the common lines anchor at the insertion point.
                    anchors.append((i, j, 0))
                } else if let line = mapX[i], mapY[j] == line {
                    anchors.append((i, j, line))
                }
            }
        }
        guard !anchors.isEmpty else { return whole }

        func same(_ p: [UInt8], _ pi: LineIndex, _ pr: Range<Int>, _ q: [UInt8], _ qi: LineIndex,
                  _ qr: Range<Int>) throws(DiffError) -> Bool {
            try sameLines(p, pi, pr, q, qi, qr, options: local)
        }
        var pieces: [Piece] = []
        var cursor = (x: 0, y: 0, o: 0)
        func gap(to end: (x: Int, y: Int, o: Int)) throws(DiffError) {
            let px = cursor.x ..< end.x, py = cursor.y ..< end.y, po = cursor.o ..< end.o
            guard !(px.isEmpty && py.isEmpty && po.isEmpty) else { return }
            let kind: MergeRegionKind, choice: MergeChoice
            if try same(x, xy.linesA, px, y, xy.linesB, py) {
                (kind, choice) = (.equal, .none)
            } else {
                let xIsBase = try same(x, xy.linesA, px, o, ox.linesA, po)
                let yIsBase = try same(y, xy.linesB, py, o, ox.linesA, po)
                switch (xIsBase, yIsBase) {
                case (true, false): (kind, choice) = (.auto, .b)
                case (false, true): (kind, choice) = (.auto, .a)
                default: (kind, choice) = (.conflict, .none)
                }
            }
            pieces.append(Piece(kind: kind, choice: choice,
                                a: aRange.lowerBound + px.lowerBound ..< aRange.lowerBound + px.upperBound,
                                b: bRange.lowerBound + py.lowerBound ..< bRange.lowerBound + py.upperBound,
                                base: baseRange.lowerBound + po.lowerBound ..< baseRange.lowerBound + po.upperBound))
        }
        for anchor in anchors {
            try gap(to: anchor)
            let step = insertion ? 0 : 1
            pieces.append(Piece(kind: .equal, choice: .none,
                                a: aRange.lowerBound + anchor.x ..< aRange.lowerBound + anchor.x + 1,
                                b: bRange.lowerBound + anchor.y ..< bRange.lowerBound + anchor.y + 1,
                                base: baseRange.lowerBound + anchor.o ..< baseRange.lowerBound + anchor.o + step))
            cursor = (anchor.x + 1, anchor.y + 1, anchor.o + step)
        }
        try gap(to: (xy.linesA.count, xy.linesB.count, ox.linesA.count))
        return pieces
    }

    /// A two-way merge of A and B with no common ancestor (git's add/add
    /// conflicts pass an empty base): every place where A and B differ is a
    /// conflict, and the lines they share stay common between them.
    public static func mergeWithoutBase(a: [UInt8], b: [UInt8],
                                        options: DiffOptions = DiffOptions()) throws(DiffError) -> Merge3Result {
        let merged = try merge(base: [], a: a, b: b, options: options)
        var regions = merged.regions
        for index in regions.indices where regions[index].kind == .auto {
            regions[index].kind = .conflict
            regions[index].choice = .none
            regions[index].autoChoice = .none
        }
        return Merge3Result(regions: regions, base: [], a: a, b: b, diffAB: merged.diffAB,
                            diffBaseA: merged.diffBaseA, diffBaseB: merged.diffBaseB, whitespace: merged.whitespace)
    }

    /// True when A lines `aRange` and B lines `bRange` are the same lines
    /// under the whitespace mode of `options`: both sides made the same edit.
    private static func sameLines(_ a: [UInt8], _ linesA: LineIndex, _ aRange: Range<Int>,
                                  _ b: [UInt8], _ linesB: LineIndex, _ bRange: Range<Int>,
                                  options: DiffOptions) throws(DiffError) -> Bool {
        guard aRange.count == bRange.count else { return false }
        if aRange.isEmpty { return true }
        let x = a[linesA.range(aRange.lowerBound).lowerBound ..< linesA.range(aRange.upperBound - 1).upperBound]
        let y = b[linesB.range(bRange.lowerBound).lowerBound ..< linesB.range(bRange.upperBound - 1).upperBound]
        if x.elementsEqual(y) { return true }
        if options.whitespace == .exact { return false }
        var serial = options
        serial.parallel = false
        return try TextDiff.cancellableDiff(Array(x), Array(y), options: serial).isIdentical
    }

    /// The edits of a base-to-side diff (base on the left) in base order.
    /// Neighbouring non-equal blocks (a delete next to an insert, say) are
    /// one edit. Two edits of one side are always at least one base line
    /// apart.
    ///
    /// A pure insertion or deletion next to equal lines can often sit in
    /// several places ("slide"): inserting a "}" into a run of "}" lines,
    /// say. Where the two-way diff puts it depends on the rest of the file,
    /// so the same insertion made by A and by B could land at different base
    /// points and be taken twice. Each one is therefore moved as far down as
    /// it goes (lines compared byte for byte), so equal edits meet.
    private static func sideEdits(_ diff: TextDiffResult, _ base: [UInt8], _ side: [UInt8]) -> [Edit] {
        var edits: [Edit] = []
        for block in diff.blocks where block.kind != .equal {
            if let last = edits.last, last.base.upperBound == block.a.lowerBound,
               last.side.upperBound == block.b.lowerBound {
                edits[edits.count - 1].base = last.base.lowerBound ..< block.a.upperBound
                edits[edits.count - 1].side = last.side.lowerBound ..< block.b.upperBound
            } else {
                edits.append(Edit(base: block.a, side: block.b))
            }
        }

        let linesBase = diff.linesA, linesSide = diff.linesB
        func sameLine(_ x: [UInt8], _ index: LineIndex, _ i: Int, _ j: Int) -> Bool {
            x[index.range(i)].elementsEqual(x[index.range(j)])
        }
        // From the last edit up, so each edit can slide into the room its
        // successor left; an edit that reaches its successor joins it.
        var slid: [Edit] = []  // in reverse order
        for var edit in edits.reversed() {
            let limit = slid.last?.base.lowerBound ?? linesBase.count
            if edit.base.isEmpty {
                while edit.base.lowerBound < limit
                        && sameLine(side, linesSide, edit.side.lowerBound, edit.side.upperBound) {
                    edit.base = edit.base.lowerBound + 1 ..< edit.base.upperBound + 1
                    edit.side = edit.side.lowerBound + 1 ..< edit.side.upperBound + 1
                }
            } else if edit.side.isEmpty {
                while edit.base.upperBound < limit
                        && sameLine(base, linesBase, edit.base.lowerBound, edit.base.upperBound) {
                    edit.base = edit.base.lowerBound + 1 ..< edit.base.upperBound + 1
                    edit.side = edit.side.lowerBound + 1 ..< edit.side.upperBound + 1
                }
            }
            if let next = slid.last, edit.base.upperBound == next.base.lowerBound {
                slid[slid.count - 1] = Edit(base: edit.base.lowerBound ..< next.base.upperBound,
                                            side: edit.side.lowerBound ..< next.side.upperBound)
            } else {
                slid.append(edit)
            }
        }
        return slid.reversed()
    }

    /// Throws `DiffError.tooLarge` unless the base (`baseCount` bytes) and
    /// any merged text of A (`aCount` bytes) and B (`bCount` bytes) stay
    /// under 2 GiB, the engine's limit for one text. Two line feeds at most
    /// are added to a merged text, where an unterminated last line is
    /// followed by more text.
    static func checkSize(base baseCount: Int, _ aCount: Int, _ bCount: Int) throws(DiffError) {
        guard baseCount < Int(Int32.max), aCount + bCount + 2 < Int(Int32.max) else { throw .tooLarge }
    }

    /// Below this many input bytes, three serial diffs beat dispatching.
    static let parallelMinBytes = 64 << 10
}

/// Results of the three diffs, written by `concurrentPerform` workers.
///
/// `@unchecked Sendable`: each slot is written by exactly one worker and read
/// only after `concurrentPerform` (or the serial loop) has returned, which
/// orders the writes before the reads.
private final class DiffSlots: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Result<TextDiffResult, DiffError>?>

    init() {
        storage = .allocate(capacity: 3)
        storage.initialize(repeating: nil, count: 3)
    }

    deinit {
        storage.deinitialize(count: 3)
        storage.deallocate()
    }

    func put(_ i: Int, _ result: Result<TextDiffResult, DiffError>) { storage[i] = result }

    func get(_ i: Int) throws(DiffError) -> TextDiffResult {
        guard let result = storage[i] else { throw .cancelled }
        return try result.get()
    }
}

/// One edit of a base-to-side diff: base lines `base` became side lines
/// `side`.
private struct Edit {
    var base: Range<Int>
    var side: Range<Int>
}

/// A group of edits of A and B that the merge decides together.
///
/// Edits of the two sides are grouped when they overlap in base: their base
/// ranges share a line, or two non-empty ranges touch (one ends where the
/// other starts), or one side inserts at the same point as the other, or
/// inside the base lines the other replaced. An insertion that only touches
/// an edge of the other side's edit is not grouped with it: the order of the
/// two is clear (the insertion goes before or after the replaced lines), so
/// each is decided on its own.
private struct Chunk {
    /// The base lines the chunk covers: the union of its edits' base ranges.
    var base = 0 ..< 0
    var hasA = false, hasB = false
    /// Side lines minus base lines over the chunk's edits of A and of B.
    var deltaA = 0, deltaB = 0
    /// Per side: the furthest end of a non-empty base range, and the point
    /// of the last insertion (empty base range), or -1.
    private var endA = -1, endB = -1, insertA = -1, insertB = -1

    var isEmpty: Bool { !hasA && !hasB }

    /// True when an edit of base lines `range` on one side (A when
    /// `otherSideOf` is true) overlaps an edit of the other side already in
    /// the chunk. Edits are added in base order (by start, then end), so
    /// `range` starts at or after every edit in the chunk and comparing with
    /// the furthest end is enough.
    func overlaps(_ range: Range<Int>, otherSideOf fromA: Bool) -> Bool {
        let end = fromA ? endB : endA, insert = fromA ? insertB : insertA
        if range.isEmpty { return range.lowerBound < end || range.lowerBound == insert }
        return range.lowerBound <= end
    }

    mutating func add(_ edit: Edit, fromA: Bool) {
        base = isEmpty ? edit.base : base.lowerBound ..< max(base.upperBound, edit.base.upperBound)
        let delta = edit.side.count - edit.base.count
        if fromA {
            hasA = true
            deltaA += delta
            if edit.base.isEmpty { insertA = edit.base.lowerBound } else { endA = max(endA, edit.base.upperBound) }
        } else {
            hasB = true
            deltaB += delta
            if edit.base.isEmpty { insertB = edit.base.lowerBound } else { endB = max(endB, edit.base.upperBound) }
        }
    }
}

/// Collects regions in order, tracking the next line of A, B and base.
/// Neighbouring equal regions are joined.
private struct RegionBuilder {
    var regions: [MergeRegion] = []
    var a = 0, b = 0, base = 0

    /// An equal region up to base line `end`: outside the chunks, A, B and
    /// base are in step.
    mutating func equal(upTo end: Int) {
        let n = end - base
        guard n > 0 else { return }
        append(kind: .equal, choice: .none, aRange: a ..< a + n, bRange: b ..< b + n, base: base ..< end)
    }

    mutating func append(kind: MergeRegionKind, choice: MergeChoice,
                         aRange: Range<Int>, bRange: Range<Int>, base range: Range<Int>) {
        if kind == .equal, let last = regions.last, last.kind == .equal {
            regions[regions.count - 1].aRange = last.aRange.lowerBound ..< aRange.upperBound
            regions[regions.count - 1].bRange = last.bRange.lowerBound ..< bRange.upperBound
            regions[regions.count - 1].baseRange = last.baseRange.lowerBound ..< range.upperBound
        } else {
            regions.append(MergeRegion(kind: kind, choice: choice, autoChoice: choice,
                                       aRange: aRange, bRange: bRange, baseRange: range,
                                       mergedRange: 0 ..< 0))
        }
        a = aRange.upperBound
        b = bRange.upperBound
        base = range.upperBound
    }
}
