// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

// Public data model of the two-way text diff engine.

/// How whitespace affects line and word matching. It never changes the text
/// that is shown: ranges always point into the original bytes.
public enum WhitespaceMode: Int, Sendable, CaseIterable {
    /// Exact byte comparison, line terminator included.
    case exact = 0
    /// LF, CRLF and CR compare equal: the terminator is not part of a line's
    /// key, and in word diffs every terminator is the same token.
    case ignoreLineEndings = 1
    /// Like `ignoreLineEndings`, and leading and trailing spaces and tabs of
    /// every line are ignored as well (they are never matched or highlighted).
    case ignoreEdgeWhitespace = 2
}

/// What a block of lines represents.
public enum BlockKind: String, Sendable, CaseIterable {
    /// The same lines on both sides (under the whitespace mode in effect).
    case equal
    /// Lines only on the B side. The A range is empty, at the insertion point.
    case insert
    /// Lines only on the A side. The B range is empty, at the deletion point.
    case delete
    /// Paired lines that differ. Always 1:1: `a.count == b.count`.
    case change
}

/// What an intra-line hunk does, so renderers can tell a replacement from a
/// caret (an insertion point on the other side).
public enum WordHunkKind: String, Sendable, CaseIterable {
    /// Text on both sides.
    case replace
    /// Text only on the B side; A has an insertion point.
    case insertOnly
    /// Text only on the A side; B has an insertion point.
    case deleteOnly
}

/// An intra-line difference inside a changed line pair.
///
/// `a` and `b` are byte columns relative to the start of line `aLine` in A
/// and line `bLine` in B. One side may be empty: it is then an insertion
/// point (a caret) on that side.
public struct WordHunk: Sendable, Equatable, Hashable {
    public var aLine: Int
    public var bLine: Int
    public var a: Range<Int>
    public var b: Range<Int>

    public init(aLine: Int, bLine: Int, a: Range<Int>, b: Range<Int>) {
        self.aLine = aLine
        self.bLine = bLine
        self.a = a
        self.b = b
    }

    /// Derived from the ranges: an empty side is an insertion point.
    public var kind: WordHunkKind {
        if a.isEmpty && !b.isEmpty { return .insertOnly }
        if b.isEmpty && !a.isEmpty { return .deleteOnly }
        return .replace
    }
}

/// A run of lines. Ranges are 0-based, half-open line indices. The blocks of
/// a result are ordered and together cover both files exactly once.
public struct DiffBlock: Sendable, Equatable, Hashable {
    public var kind: BlockKind
    public var a: Range<Int>
    public var b: Range<Int>
    /// Intra-line hunks, in line order. Only `.change` blocks have any.
    public var words: [WordHunk]

    public init(kind: BlockKind, a: Range<Int>, b: Range<Int>, words: [WordHunk] = []) {
        self.kind = kind
        self.a = a
        self.b = b
        self.words = words
    }

    // Classification from the ranges alone: a difference with
    // both sides non-empty is a change, with only B an insert, with only A a
    // delete. Equal blocks are none of these.

    /// A difference whose A and B ranges are both non-empty.
    public var isChange: Bool { kind != .equal && !a.isEmpty && !b.isEmpty }
    /// A difference with lines only on the B side.
    public var isInsert: Bool { kind != .equal && a.isEmpty && !b.isEmpty }
    /// A difference with lines only on the A side.
    public var isDelete: Bool { kind != .equal && !a.isEmpty && b.isEmpty }
}

/// Tuning knobs of `TextDiff`. The defaults are the production settings; the
/// heuristics only trade minimality for bounded time on pathological input.
public struct DiffOptions: Sendable, Equatable {
    public var whitespace: WhitespaceMode
    /// Refine change blocks concurrently when there is enough work.
    public var parallel: Bool
    /// Mixed blocks with more word tokens than this (A + B) skip word-level
    /// alignment and are reported as a delete followed by an insert. Blocks
    /// of more than 64 bytes per allowed token are split without being
    /// tokenized. A block of one line against one line is exempt: its cost
    /// is already bounded by Myers' prefix and suffix stripping and cost
    /// cap. 0 means unlimited.
    public var maxRefineTokens: Int
    /// Myers gives up on minimality after max(myersMinCost, sqrt(N)) edit
    /// steps at line level, or myersMinCost steps at word level, and splits at
    /// the furthest-reaching point found so far. 0 means always exact
    /// (worst case O(N*D)).
    public var myersMinCost: Int
    /// Mixed blocks bigger than this many bytes (A + B) first pair the lines
    /// that are equal ignoring whitespace and line endings; only the gaps
    /// between those pairs get full word alignment. 0 means never.
    public var prePairBytes: Int
    /// When false, mixed blocks get no word-level refinement at all: each is
    /// reported as a delete followed by an insert. For callers that only
    /// need the line alignment (the base diffs of a three-way merge).
    public var wordRefinement: Bool
    /// Cooperative cancellation token, honoured by `TextDiff.cancellableDiff`
    /// and `TextDiff.asyncDiff`. The non-throwing `TextDiff.diff` ignores it.
    public var cancellation: CancellationFlag?

    /// The default hard valve for `maxRefineTokens`.
    public static let defaultMaxRefineTokens = 500_000

    public init(whitespace: WhitespaceMode = .exact,
                parallel: Bool = true,
                maxRefineTokens: Int = DiffOptions.defaultMaxRefineTokens,
                myersMinCost: Int = 256,
                prePairBytes: Int = 64 << 10,
                wordRefinement: Bool = true,
                cancellation: CancellationFlag? = nil) {
        self.whitespace = whitespace
        self.parallel = parallel
        self.maxRefineTokens = maxRefineTokens
        self.myersMinCost = myersMinCost
        self.prePairBytes = prePairBytes
        self.wordRefinement = wordRefinement
        self.cancellation = cancellation
    }
}

/// Line index of a text buffer: `starts[i] ..< starts[i + 1]` is the byte
/// range of line `i`, terminator included. `starts` always begins with 0 and
/// ends with the buffer length.
public struct LineIndex: Sendable, Equatable {
    public let starts: [Int32]

    public init(starts: [Int32]) {
        precondition(!starts.isEmpty && starts[0] == 0, "a line index starts at offset 0")
        self.starts = starts
    }

    /// Number of lines.
    public var count: Int { starts.count - 1 }

    /// Byte range of line `i`, terminator included.
    public func range(_ i: Int) -> Range<Int> { Int(starts[i]) ..< Int(starts[i + 1]) }
}

/// The outcome of a two-way diff.
public struct TextDiffResult: Sendable, Equatable {
    public var blocks: [DiffBlock]
    public var linesA: LineIndex
    public var linesB: LineIndex
    /// True when A ends with a line terminator. A difference only in the
    /// final newline is always a change of the last line pair: at `.exact`
    /// because the terminator is part of the line, at the other modes
    /// because an end-of-file marker is applied after the comparison.
    /// Renderers use these flags for "no newline at end of file" markers.
    public var aHasFinalNewline: Bool
    /// True when B ends with a line terminator.
    public var bHasFinalNewline: Bool

    public init(blocks: [DiffBlock], linesA: LineIndex, linesB: LineIndex,
                aHasFinalNewline: Bool, bHasFinalNewline: Bool) {
        self.blocks = blocks
        self.linesA = linesA
        self.linesB = linesB
        self.aHasFinalNewline = aHasFinalNewline
        self.bHasFinalNewline = bHasFinalNewline
    }

    /// Number of differences: blocks that are not `.equal`.
    public var changeCount: Int { blocks.lazy.filter { $0.kind != .equal }.count }

    /// True when the files compare equal under the options used.
    public var isIdentical: Bool { changeCount == 0 }
}
