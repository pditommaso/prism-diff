// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin

/// Word-level refinement of a mixed block (deleted lines next to inserted
/// lines) and pairing of its lines by longest equal word run.
///
/// Steps:
/// 1. big blocks first pair the lines that are equal ignoring whitespace and
///    line endings (`prePairRefine`);
/// 2. Myers over the word tokens of the whole block;
/// 3. equal word runs are grouped per (A line, B line) and scored by their
///    length in characters (UTF-16 units, as an `NSRange` would count
///    them, not UTF-8 bytes); lines are paired greedily by descending score;
/// 4. unpaired lines become a delete then an insert, paired lines become
///    changes, each pair is word-diffed again on its own, and consecutive
///    changes are merged.
///
/// One refiner serves one worker: it owns reusable scratch buffers and is not
/// thread-safe.
final class Refiner {
    private let context: RefineContext
    private let myers: Myers
    private var tokensA = Tokens(), tokensB = Tokens()
    /// Per line pair scratch.
    private var pairA = Tokens(), pairB = Tokens()
    private let pairInterner = Interner(expected: 256)

    /// Lines handled between two polls of the cancellation token while
    /// pre-pairing.
    static let prePairBatch = 4096

    /// A token covers at most this many bytes on average in any realistic
    /// text (a long identifier). A block with more than `maxTokens` times
    /// this many bytes is split without tokenizing it at all.
    static let maxBytesPerToken = 64

    /// A single line pair may use this many times `maxTokens` tokens once
    /// the common prefix and suffix of the two lines are folded away. Above
    /// that, a one-line block is a delete and an insert, which bounds the
    /// memory of a huge minified line (16 bytes per token) to a few hundred
    /// MB instead of growing with the line.
    static let pairTokenFactor = 16

    /// Ids of the folded common prefix and suffix tokens of a line pair.
    /// Interned ids are never negative, so these match only each other.
    static let headId: Int32 = -1, tailId: Int32 = -2

    init(_ context: RefineContext) {
        self.context = context
        myers = Myers(minCost: context.minCost, scaled: false, cancellation: context.cancellation)
    }

    func refine(_ ar: Range<Int>, _ br: Range<Int>) -> [DiffBlock] {
        if context.prePairBytes > 0 && ar.count > 1 && br.count > 1
            && context.byteCount(ar, br) > context.prePairBytes {
            return prePairRefine(ar, br)
        }
        return refineCore(ar, br)
    }

    /// Big blocks: lines equal after whitespace and line-ending normalisation
    /// are paired up front (unique anchors plus Myers, as at line level), and
    /// only the gaps between them are aligned word by word. Linear when every
    /// line differs only in its terminator or indentation.
    private func prePairRefine(_ ar: Range<Int>, _ br: Range<Int>) -> [DiffBlock] {
        let interner = Interner(expected: ar.count + br.count)
        var idsA = [Int32](), idsB = [Int32]()
        idsA.reserveCapacity(ar.count)
        idsB.reserveCapacity(br.count)
        let split = [DiffBlock(kind: .delete, a: ar, b: br.lowerBound ..< br.lowerBound),
                     DiffBlock(kind: .insert, a: ar.upperBound ..< ar.upperBound, b: br)]
        for line in ar {
            if (line - ar.lowerBound) & (Refiner.prePairBatch - 1) == 0 && context.cancellation.isCancelled {
                return split
            }
            let key = lineKey(context.pa, Int(context.startsA[line]), Int(context.startsA[line + 1]), 2)
            idsA.append(interner.intern(context.pa + key.start, key.end - key.start))
        }
        for line in br {
            if (line - br.lowerBound) & (Refiner.prePairBatch - 1) == 0 && context.cancellation.isCancelled {
                return split
            }
            let key = lineKey(context.pb, Int(context.startsB[line]), Int(context.startsB[line + 1]), 2)
            idsB.append(interner.intern(context.pb + key.start, key.end - key.start))
        }
        // Keep only lines whose key occurs on both sides: the others can never
        // match, so dropping them preserves the LCS and makes this pass cost
        // what the sides share (nothing for disjoint blocks).
        var sides = [UInt8](repeating: 0, count: interner.count)
        for id in idsA { sides[Int(id)] |= 1 }
        for id in idsB { sides[Int(id)] |= 2 }
        var keptA: [Int32] = [], keptB: [Int32] = [], keptIdsA: [Int32] = [], keptIdsB: [Int32] = []
        for (i, id) in idsA.enumerated() where sides[Int(id)] == 3 {
            keptA.append(Int32(i))
            keptIdsA.append(id)
        }
        for (i, id) in idsB.enumerated() where sides[Int(id)] == 3 {
            keptB.append(Int32(i))
            keptIdsB.append(id)
        }
        if keptIdsA.isEmpty { return refineCore(ar, br) }
        var (ma, mb) = keptIdsA.withUnsafeBufferPointer { x in
            keptIdsB.withUnsafeBufferPointer { y in
                TextDiff.lineMatches(x.baseAddress!, x.count, y.baseAddress!, y.count,
                                     idCount: interner.count, minCost: context.minCost,
                                     cancellation: context.cancellation)
            }
        }
        if context.cancellation.isCancelled { return split }
        if ma.isEmpty { return refineCore(ar, br) }
        for k in 0 ..< ma.count {
            ma[k] = keptA[Int(ma[k])]
            mb[k] = keptB[Int(mb[k])]
        }
        var out: [DiffBlock] = []
        var cursorA = ar.lowerBound, cursorB = br.lowerBound
        for k in 0 ... ma.count {
            if k & (Refiner.prePairBatch - 1) == 0 && context.cancellation.isCancelled { return split }
            let la = k < ma.count ? ar.lowerBound + Int(ma[k]) : ar.upperBound
            let lb = k < mb.count ? br.lowerBound + Int(mb[k]) : br.upperBound
            if la > cursorA && lb > cursorB {
                for block in refineCore(cursorA ..< la, cursorB ..< lb) { appendMerging(&out, block) }
            } else if la > cursorA {
                appendMerging(&out, DiffBlock(kind: .delete, a: cursorA ..< la, b: cursorB ..< cursorB))
            } else if lb > cursorB {
                appendMerging(&out, DiffBlock(kind: .insert, a: la ..< la, b: cursorB ..< lb))
            }
            if k == ma.count { break }
            guard let words = pairWords(la, lb) else { return split }
            appendMerging(&out, DiffBlock(kind: .change, a: la ..< la + 1, b: lb ..< lb + 1, words: words))
            cursorA = la + 1
            cursorB = lb + 1
        }
        return out
    }

    private func refineCore(_ ar: Range<Int>, _ br: Range<Int>) -> [DiffBlock] {
        let split = [DiffBlock(kind: .delete, a: ar, b: br.lowerBound ..< br.lowerBound),
                     DiffBlock(kind: .insert, a: ar.upperBound ..< ar.upperBound, b: br)]
        // One line against one line is the line-pair diff. Its common prefix
        // and suffix are folded into one token each and it gets the larger
        // `pairLimit`, so a long line with a few edits (minified JSON) keeps
        // its word highlights.
        if ar.count == 1 && br.count == 1 {
            guard let pair = pairDiff(ar.lowerBound, br.lowerBound), pair.matched else { return split }
            return [DiffBlock(kind: .change, a: ar, b: br, words: pair.words)]
        }
        // Bigger blocks stop as soon as they pass the limit.
        let limit = context.maxTokens > 0 ? context.maxTokens : Int.max
        if limit < Int.max && context.byteCount(ar, br) > limit * Refiner.maxBytesPerToken {
            return split
        }
        tokensA.removeAll()
        tokensB.removeAll()
        // Never more distinct tokens than the limit allows, so the table is
        // sized for that, not for the block's bytes.
        let interner = Interner(expected: min(context.byteCount(ar, br) / 8, limit) + 16)
        guard tokenize(ar, into: &tokensA, context.pa, context.startsA, interner: interner, limit: limit),
              tokenize(br, into: &tokensB, context.pb, context.startsB, interner: interner,
                       limit: limit - tokensA.count)
        else { return split }

        // Myers over the word tokens of the whole block.
        myers.reset()
        runMyers(tokensA, tokensB)
        if context.cancellation.isCancelled { return split }

        // Equal word runs, split per (A line, B line) and scored by their
        // length in characters.
        var runLineA: [Int32] = [], runLineB: [Int32] = [], runScore: [Int32] = []
        let ma = myers.matchesA, mb = myers.matchesB
        let pa = context.pa
        var k = 0
        while k < ma.count {
            let la = tokensA.line(Int(ma[k])), lb = tokensB.line(Int(mb[k]))
            var score = Int32(utf16Length(pa, tokensA.start(Int(ma[k])), tokensA.end(Int(ma[k]))))
            var j = k + 1
            while j < ma.count && ma[j] == ma[j - 1] + 1 && mb[j] == mb[j - 1] + 1
                    && tokensA.line(Int(ma[j])) == la && tokensB.line(Int(mb[j])) == lb {
                score += Int32(utf16Length(pa, tokensA.start(Int(ma[j])), tokensA.end(Int(ma[j]))))
                j += 1
            }
            runLineA.append(la)
            runLineB.append(lb)
            runScore.append(score)
            k = j
        }

        // Greedy by descending score, ties to the earliest run. This equals
        // the recursive "pair the best equality, then recurse above and below":
        // a run is accepted iff it lies strictly inside the region left
        // between pairs already accepted.
        let order = (0 ..< runScore.count).sorted {
            runScore[$0] != runScore[$1] ? runScore[$0] > runScore[$1] : $0 < $1
        }
        var pairedA: [Int32] = [], pairedB: [Int32] = []   // sorted by A line
        for run in order {
            let la = runLineA[run], lb = runLineB[run]
            var lo = 0, hi = pairedA.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if pairedA[mid] < la { lo = mid + 1 } else { hi = mid }
            }
            if lo < pairedA.count && pairedA[lo] == la { continue }
            if lo > 0 && pairedB[lo - 1] >= lb { continue }
            if lo < pairedA.count && pairedB[lo] <= lb { continue }
            pairedA.insert(la, at: lo)
            pairedB.insert(lb, at: lo)
        }

        // Gaps become a delete then an insert; pairs become changes, merged
        // when consecutive.
        var out: [DiffBlock] = []
        var cursorA = ar.lowerBound, cursorB = br.lowerBound
        for i in 0 ..< pairedA.count {
            let la = Int(pairedA[i]), lb = Int(pairedB[i])
            // `pairWords` polls the cancellation token before each pair.
            guard let words = pairWords(la, lb) else { return split }
            if la > cursorA { out.append(DiffBlock(kind: .delete, a: cursorA ..< la, b: cursorB ..< cursorB)) }
            if lb > cursorB { out.append(DiffBlock(kind: .insert, a: la ..< la, b: cursorB ..< lb)) }
            appendMerging(&out, DiffBlock(kind: .change, a: la ..< la + 1, b: lb ..< lb + 1, words: words))
            cursorA = la + 1
            cursorB = lb + 1
        }
        if ar.upperBound > cursorA {
            out.append(DiffBlock(kind: .delete, a: cursorA ..< ar.upperBound, b: cursorB ..< cursorB))
        }
        if br.upperBound > cursorB {
            out.append(DiffBlock(kind: .insert, a: ar.upperBound ..< ar.upperBound, b: cursorB ..< br.upperBound))
        }
        return out
    }

    /// Tokenizes lines `range` into `tokens`. Returns false, leaving the
    /// tokens incomplete, when cancelled or when more than `limit` tokens
    /// would be needed. Both are checked every `Tokens.checkInterval` tokens
    /// (so inside a long line too) and every `prePairBatch` lines.
    private func tokenize(_ range: Range<Int>, into tokens: inout Tokens, _ p: UnsafePointer<UInt8>,
                          _ starts: [Int32], interner: Interner, limit: Int) -> Bool {
        let cancellation = context.cancellation
        for line in range {
            if (line - range.lowerBound) & (Refiner.prePairBatch - 1) == Refiner.prePairBatch - 1 {
                if cancellation.isCancelled || tokens.count > limit { return false }
            }
            guard tokens.tokenizeLine(p, Int(starts[line]), Int(starts[line + 1]), line: line,
                                      ws: context.ws, interner: interner, limit: limit,
                                      cancellation: cancellation)
            else { return false }
        }
        return tokens.count <= limit && !cancellation.isCancelled
    }

    private func runMyers(_ x: Tokens, _ y: Tokens) {
        x.ids.withUnsafeBufferPointer { ia in
            y.ids.withUnsafeBufferPointer { ib in
                if let pa = ia.baseAddress, let pb = ib.baseAddress {
                    myers.diff(pa, 0, ia.count, pb, 0, ib.count)
                }
            }
        }
    }

    /// Token limit of one line pair (both sides together).
    private var pairLimit: Int {
        context.maxTokens > 0 ? context.maxTokens * Refiner.pairTokenFactor : Int.max
    }

    /// Word hunks of a paired line inside a bigger block. Nil only when the
    /// diff was cancelled. A pair over `pairLimit` (possible only for lines
    /// paired as equal ignoring whitespace) is marked changed as a whole.
    private func pairWords(_ la: Int, _ lb: Int) -> [WordHunk]? {
        if let pair = pairDiff(la, lb) { return pair.words }
        if context.cancellation.isCancelled { return nil }
        let sa = Int(context.startsA[la]), sb = Int(context.startsB[lb])
        let endA = contentEnd(context.pa, sa, Int(context.startsA[la + 1]))
        let endB = contentEnd(context.pb, sb, Int(context.startsB[lb + 1]))
        return [WordHunk(aLine: la, bLine: lb, a: 0 ..< endA - sa, b: 0 ..< endB - sb)]
    }

    /// Word-diffs one paired line on its own. `matched` is false when the
    /// two lines share no token. Nil when cancelled or when the pair needs
    /// more than `pairLimit` tokens.
    ///
    /// The common byte prefix and suffix of the two contents, cut back to a
    /// token boundary that both sides share, are folded into one token each
    /// (`headId`, `tailId`). The hunks are the same as with every token
    /// spelled out: Myers would strip those tokens as common prefix and
    /// suffix anyway (the suffix is kept clear of the whole common prefix so
    /// that it never takes tokens the prefix strip would have matched, and
    /// it is folded only when both terminators are the same token), but
    /// a long line with a local edit costs only its edited middle.
    private func pairDiff(_ la: Int, _ lb: Int) -> (words: [WordHunk], matched: Bool)? {
        let cancellation = context.cancellation
        if cancellation.isCancelled { return nil }
        pairA.removeAll()
        pairB.removeAll()
        let pa = context.pa, pb = context.pb, ws = context.ws
        let ea = Int(context.startsA[la + 1]), eb = Int(context.startsB[lb + 1])
        let ca = Tokens.content(pa, Int(context.startsA[la]), ea, ws: ws)
        let cb = Tokens.content(pb, Int(context.startsB[lb]), eb, ws: ws)
        let lengthA = ca.stop - ca.start, lengthB = cb.stop - cb.start
        let shared = min(lengthA, lengthB)

        let prefix = commonPrefix(pa + ca.start, pb + cb.start, shared)
        var head = 0
        if prefix == lengthA && prefix == lengthB {
            head = prefix
        } else if prefix > 0 {
            // A boundary at k needs bytes k - 1 and k on both sides to be
            // common, so k < prefix.
            head = prefix - 1
            while head > 0 && !isTokenBoundary(pa[ca.start + head - 1], pa[ca.start + head]) { head -= 1 }
        }
        // The suffix is a token suffix only when the terminator tokens that
        // follow it are equal; otherwise Myers would not strip it either.
        let terminatorA = ea - ca.terminator, terminatorB = eb - cb.terminator
        let sameTerminator = ws == 0
            ? terminatorA == terminatorB && memcmp(pa + ca.terminator, pb + cb.terminator, terminatorA) == 0
            : (terminatorA == 0) == (terminatorB == 0)
        let suffix = sameTerminator ? commonSuffix(pa + ca.stop, pb + cb.stop, shared - prefix) : 0
        var tail = 0
        if suffix > 0 {
            tail = suffix - 1
            while tail > 0 && !isTokenBoundary(pa[ca.stop - tail - 1], pa[ca.stop - tail]) { tail -= 1 }
        }

        let limit = pairLimit
        let middle = lengthA + lengthB - 2 * (head + tail)
        let interner: Interner
        if middle < 1024 {
            interner = pairInterner
            interner.reset()
        } else {
            interner = Interner(expected: min(middle / 16, 1 << 20) + 16)
        }
        guard Refiner.fill(&pairA, pa, ca, ea, head: head, tail: tail, line: la, ws: ws,
                           interner: interner, limit: limit, cancellation: cancellation),
              Refiner.fill(&pairB, pb, cb, eb, head: head, tail: tail, line: lb, ws: ws,
                           interner: interner, limit: limit - pairA.count, cancellation: cancellation),
              pairA.count + pairB.count <= limit
        else { return nil }
        myers.reset()
        runMyers(pairA, pairB)
        if cancellation.isCancelled { return nil }
        return (hunks(pairA, pairB, myers.matchesA, myers.matchesB, la, lb), !myers.matchesA.isEmpty)
    }

    /// Tokens of one side of a line pair: the folded prefix, the middle, the
    /// folded suffix and the terminator.
    private static func fill(_ tokens: inout Tokens, _ p: UnsafePointer<UInt8>,
                             _ c: (start: Int, stop: Int, terminator: Int), _ e: Int,
                             head: Int, tail: Int, line: Int, ws: Int, interner: Interner,
                             limit: Int, cancellation: CancellationFlag?) -> Bool {
        if head > 0 && !tokens.add(c.start, c.start + head, line, headId, limit: limit, cancellation: cancellation) {
            return false
        }
        guard tokens.tokenizeRun(p, c.start + head, c.stop - tail, line: line, interner: interner,
                                 limit: limit, cancellation: cancellation)
        else { return false }
        if tail > 0 && !tokens.add(c.stop - tail, c.stop, line, tailId, limit: limit, cancellation: cancellation) {
            return false
        }
        return tokens.addTerminator(p, c.terminator, e, line: line, ws: ws, interner: interner,
                                    limit: limit, cancellation: cancellation)
    }

    /// Turns the unmatched token runs between consecutive matches into hunks,
    /// in byte columns relative to the line start. An empty side is an
    /// insertion point.
    private func hunks(_ x: Tokens, _ y: Tokens, _ ma: [Int32], _ mb: [Int32],
                       _ la: Int, _ lb: Int) -> [WordHunk] {
        let lineStartA = Int(context.startsA[la]), lineStartB = Int(context.startsB[lb])
        var out: [WordHunk] = []
        var previousA = -1, previousB = -1
        for k in 0 ... ma.count {
            let nextA = k < ma.count ? Int(ma[k]) : x.count
            let nextB = k < mb.count ? Int(mb[k]) : y.count
            if nextA > previousA + 1 || nextB > previousB + 1 {
                out.append(WordHunk(aLine: la, bLine: lb,
                                    a: columns(x, previousA, nextA, lineStartA),
                                    b: columns(y, previousB, nextB, lineStartB)))
            }
            previousA = nextA
            previousB = nextB
        }
        return out
    }

    /// Columns covered by the tokens strictly between `previous` and `next`,
    /// or the insertion point between them when there are none.
    @inline(__always)
    private func columns(_ t: Tokens, _ previous: Int, _ next: Int, _ lineStart: Int) -> Range<Int> {
        if next > previous + 1 { return t.start(previous + 1) - lineStart ..< t.end(next - 1) - lineStart }
        let point: Int
        if previous >= 0 {
            point = t.end(previous)
        } else if next < t.count {
            point = t.start(next)
        } else {
            point = lineStart
        }
        return point - lineStart ..< point - lineStart
    }
}

/// Length of the common prefix of `x[0..<n]` and `y[0..<n]`.
func commonPrefix(_ x: UnsafePointer<UInt8>, _ y: UnsafePointer<UInt8>, _ n: Int) -> Int {
    var i = 0
    // memcmp whole blocks first: vectorised, so a multi-MB common prefix
    // costs a few milliseconds.
    while i + 4096 <= n && memcmp(x + i, y + i, 4096) == 0 { i += 4096 }
    while i < n && x[i] == y[i] { i += 1 }
    return i
}

/// Length of the common suffix of the `n` bytes before `xEnd` and `yEnd`.
func commonSuffix(_ xEnd: UnsafePointer<UInt8>, _ yEnd: UnsafePointer<UInt8>, _ n: Int) -> Int {
    var i = 0
    while i + 4096 <= n && memcmp(xEnd - i - 4096, yEnd - i - 4096, 4096) == 0 { i += 4096 }
    while i < n && xEnd[-i - 1] == yEnd[-i - 1] { i += 1 }
    return i
}

/// Appends a block, merging it into the previous one when both are changes
/// that touch.
@inline(__always)
func appendMerging(_ out: inout [DiffBlock], _ block: DiffBlock) {
    if block.kind == .change, let last = out.last, last.kind == .change,
       last.a.upperBound == block.a.lowerBound, last.b.upperBound == block.b.lowerBound {
        out[out.count - 1].a = last.a.lowerBound ..< block.a.upperBound
        out[out.count - 1].b = last.b.lowerBound ..< block.b.upperBound
        out[out.count - 1].words.append(contentsOf: block.words)
    } else {
        out.append(block)
    }
}

/// Length in UTF-16 units of the UTF-8 bytes `[s, e)` of `p`: one unit per
/// sequence lead byte (and per byte that is not valid UTF-8), two for a
/// four-byte sequence. Equals the byte count for ASCII.
@inline(__always)
func utf16Length(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Int {
    var units = 0
    for i in s ..< e {
        let c = p[i]
        if c & 0xC0 != 0x80 { units += c >= 0xF0 ? 2 : 1 }
    }
    return units
}
