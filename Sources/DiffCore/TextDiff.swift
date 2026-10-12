// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Dispatch

/// Entry point of the two-way text diff engine.
///
/// Pipeline:
/// 1. short-circuits (both empty, one side empty, byte-identical);
/// 2. split into lines and intern each line's whitespace-mode key into a
///    dense id;
/// 3. strip the common prefix and suffix, then anchor on lines that occur
///    exactly once on each side (Myers over the unique lines only);
/// 4. Myers on every gap between anchors, after discarding lines that never
///    occur on the other side (gaps of 32 lines or more);
/// 5. walk the matches into equal runs and mixed blocks; deletes come before
///    inserts;
/// 6. refine mixed blocks word by word (see `Refiner`), concurrently when
///    there is enough work.
///
/// `diff` always runs to completion. `cancellableDiff` (and the async
/// `asyncDiff`) honour `DiffOptions.cancellation` and throw
/// `DiffError.cancelled` instead of returning a partial result.
public enum TextDiff {

    /// Diffs two buffers to completion. `options.cancellation` is ignored.
    public static func diff(_ a: [UInt8], _ b: [UInt8], options: DiffOptions = DiffOptions()) -> TextDiffResult {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                diff(pa, pb, options: options)
            }
        }
    }

    /// Zero-copy variant, for example over memory-mapped files. The buffers
    /// only need to stay valid for the duration of the call.
    public static func diff(_ pa: UnsafeBufferPointer<UInt8>, _ pb: UnsafeBufferPointer<UInt8>,
                            options: DiffOptions = DiffOptions()) -> TextDiffResult {
        // Without a token, `run` cannot stop early.
        run(pa, pb, options: options, cancellation: nil)!
    }

    /// Diffs two buffers, polling `options.cancellation`. Throws
    /// `DiffError.cancelled` if the token is cancelled before or during the
    /// diff; the partial work is discarded.
    public static func cancellableDiff(_ a: [UInt8], _ b: [UInt8],
                                       options: DiffOptions) throws(DiffError) -> TextDiffResult {
        let result = a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                run(pa, pb, options: options, cancellation: options.cancellation)
            }
        }
        guard let result else { throw .cancelled }
        return result
    }

    /// Zero-copy variant of `cancellableDiff`.
    public static func cancellableDiff(_ pa: UnsafeBufferPointer<UInt8>, _ pb: UnsafeBufferPointer<UInt8>,
                                       options: DiffOptions) throws(DiffError) -> TextDiffResult {
        guard let result = run(pa, pb, options: options, cancellation: options.cancellation) else {
            throw .cancelled
        }
        return result
    }

    /// The pipeline. Returns nil when `cancellation` was cancelled. Inner
    /// loops that notice the cancellation stop early and leave consistent
    /// but meaningless state behind; the checks between stages turn that
    /// into nil, so a partial result never escapes. The token is monotonic,
    /// so any early stop is always followed by a failed stage check.
    private static func run(_ pa: UnsafeBufferPointer<UInt8>, _ pb: UnsafeBufferPointer<UInt8>,
                            options: DiffOptions, cancellation: CancellationFlag?) -> TextDiffResult? {
        if cancellation.isCancelled { return nil }
        let linesA = LineIndex(starts: splitLines(pa))
        let linesB = LineIndex(starts: splitLines(pb))
        let nA = linesA.count, nB = linesB.count
        let finalA = hasFinalNewline(pa), finalB = hasFinalNewline(pb)

        func result(_ blocks: [DiffBlock]) -> TextDiffResult {
            TextDiffResult(blocks: blocks, linesA: linesA, linesB: linesB,
                           aHasFinalNewline: finalA, bHasFinalNewline: finalB)
        }
        if cancellation.isCancelled { return nil }

        // 1. Short-circuits.
        if nA == 0 && nB == 0 { return result([]) }
        if nA == 0 { return result([DiffBlock(kind: .insert, a: 0 ..< 0, b: 0 ..< nB)]) }
        if nB == 0 { return result([DiffBlock(kind: .delete, a: 0 ..< nA, b: 0 ..< 0)]) }
        // Both buffers are non-empty here (they each have a line).
        let baseA = pa.baseAddress!, baseB = pb.baseAddress!
        if pa.count == pb.count && memcmp(baseA, baseB, pa.count) == 0 {
            return result([DiffBlock(kind: .equal, a: 0 ..< nA, b: 0 ..< nB)])
        }

        let ws = options.whitespace.rawValue

        // 2. Intern lines into dense ids.
        let interner = Interner(expected: nA + nB)
        let idsA = internLines(baseA, linesA.starts, ws, interner, cancellation)
        let idsB = internLines(baseB, linesB.starts, ws, interner, cancellation)
        if cancellation.isCancelled { return nil }

        // 3-4. Anchors, then Myers on the gaps.
        let (ma, mb) = idsA.withUnsafeBufferPointer { ia in
            idsB.withUnsafeBufferPointer { ib in
                lineMatches(ia.baseAddress!, nA, ib.baseAddress!, nB,
                            idCount: interner.count, minCost: options.myersMinCost,
                            cancellation: cancellation)
            }
        }
        if cancellation.isCancelled { return nil }

        // 5. Walk the matches into equal runs and mixed blocks.
        enum Segment { case block(DiffBlock), refine(Int) }
        var segments: [Segment] = []
        var jobs: [RefineJob] = []
        var ia = 0, ib = 0, k = 0
        let matchCount = ma.count
        while ia < nA || ib < nB {
            let nextA = k < matchCount ? Int(ma[k]) : nA
            let nextB = k < matchCount ? Int(mb[k]) : nB
            if nextA > ia && nextB > ib {
                segments.append(.refine(jobs.count))
                jobs.append(RefineJob(a: ia ..< nextA, b: ib ..< nextB))
            } else if nextA > ia {
                segments.append(.block(DiffBlock(kind: .delete, a: ia ..< nextA, b: ib ..< ib)))
            } else if nextB > ib {
                segments.append(.block(DiffBlock(kind: .insert, a: ia ..< ia, b: ib ..< nextB)))
            }
            if k >= matchCount { break }
            var run = 1
            while k + run < matchCount && ma[k + run] == ma[k] + Int32(run) && mb[k + run] == mb[k] + Int32(run) {
                run += 1
            }
            segments.append(.block(DiffBlock(kind: .equal, a: nextA ..< nextA + run, b: nextB ..< nextB + run)))
            ia = nextA + run
            ib = nextB + run
            k += run
        }

        // 6. Word refinement of mixed blocks.
        let context = RefineContext(pa: baseA, pb: baseB,
                                    startsA: linesA.starts, startsB: linesB.starts,
                                    ws: ws, maxTokens: options.maxRefineTokens,
                                    minCost: options.myersMinCost, prePairBytes: options.prePairBytes,
                                    cancellation: cancellation)
        let refined = options.wordRefinement
            ? refineAll(jobs, context: context, parallel: options.parallel)
            : splitAll(jobs)
        if cancellation.isCancelled { return nil }

        var blocks: [DiffBlock] = []
        blocks.reserveCapacity(segments.count + jobs.count + 1)
        for segment in segments {
            switch segment {
            case .block(let block): blocks.append(block)
            case .refine(let job): blocks.append(contentsOf: refined.take(job))
            }
        }
        if finalA != finalB {
            applyEOFMarker(&blocks, pa: baseA, linesA: linesA, pb: baseB, linesB: linesB)
        }
        return result(blocks)
    }

    /// Makes a difference only in the final newline visible when the
    /// whitespace mode ignored it (modes 1 and 2 leave terminators out of
    /// the comparison, so both last lines ended up in the closing equal
    /// run). As in the reference design, end-of-file markers are applied
    /// after the comparison: the last line pair becomes a change whose only
    /// word hunk is the terminator one side has and the other lacks. At mode
    /// 0 the terminator is part of the line, so the pair already differs.
    private static func applyEOFMarker(_ blocks: inout [DiffBlock], pa: UnsafePointer<UInt8>, linesA: LineIndex,
                                       pb: UnsafePointer<UInt8>, linesB: LineIndex) {
        guard let last = blocks.last, last.kind == .equal, !last.a.isEmpty else { return }
        let la = last.a.upperBound - 1, lb = last.b.upperBound - 1
        blocks.removeLast()
        if last.a.count > 1 {
            blocks.append(DiffBlock(kind: .equal, a: last.a.lowerBound ..< la, b: last.b.lowerBound ..< lb))
        }
        func terminator(_ p: UnsafePointer<UInt8>, _ lines: LineIndex, _ line: Int) -> Range<Int> {
            let range = lines.range(line)
            let end = contentEnd(p, range.lowerBound, range.upperBound)
            return end - range.lowerBound ..< range.count
        }
        let hunk = WordHunk(aLine: la, bLine: lb, a: terminator(pa, linesA, la), b: terminator(pb, linesB, lb))
        appendMerging(&blocks, DiffBlock(kind: .change, a: la ..< la + 1, b: lb ..< lb + 1, words: [hunk]))
    }

    /// Below either threshold, dispatching to worker threads costs more than
    /// it saves (about 0.1 ms per dispatch).
    static let parallelMinJobs = 8
    static let parallelMinBytes = 64 << 10

    /// Line level only: every mixed block becomes a delete then an insert.
    private static func splitAll(_ jobs: [RefineJob]) -> ResultBox {
        let results = ResultBox(count: jobs.count)
        for (j, job) in jobs.enumerated() {
            results.put(j, [DiffBlock(kind: .delete, a: job.a, b: job.b.lowerBound ..< job.b.lowerBound),
                            DiffBlock(kind: .insert, a: job.a.upperBound ..< job.a.upperBound, b: job.b)])
        }
        return results
    }

    private static func refineAll(_ jobs: [RefineJob], context: RefineContext, parallel: Bool) -> ResultBox {
        let results = ResultBox(count: jobs.count)
        guard !jobs.isEmpty else { return results }
        var bytes = 0
        if parallel && jobs.count >= parallelMinJobs {
            for job in jobs {
                bytes += context.byteCount(job.a, job.b)
                if bytes >= parallelMinBytes { break }
            }
        }
        let workers = bytes >= parallelMinBytes ? min(jobs.count, CPU.activeCount * 2) : 1
        if workers > 1 {
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                let refiner = Refiner(context)
                var j = worker
                while j < jobs.count {
                    // Once per job: on cancellation the remaining slots stay
                    // empty and the caller discards the whole result.
                    if context.cancellation.isCancelled { return }
                    results.put(j, refiner.refine(jobs[j].a, jobs[j].b))
                    j += workers
                }
            }
        } else {
            let refiner = Refiner(context)
            for (j, job) in jobs.enumerated() {
                if context.cancellation.isCancelled { break }
                results.put(j, refiner.refine(job.a, job.b))
            }
        }
        return results
    }

    /// Lines interned between two polls of the cancellation token.
    static let internCheckInterval = 1 << 16

    /// Interns the key of every line. On cancellation the remaining ids are
    /// left as 0: the array keeps its length, the content is discarded.
    static func internLines(_ p: UnsafePointer<UInt8>, _ starts: [Int32], _ ws: Int,
                            _ interner: Interner, _ cancellation: CancellationFlag?) -> [Int32] {
        let n = starts.count - 1
        return [Int32](unsafeUninitializedCapacity: n) { buffer, initialized in
            starts.withUnsafeBufferPointer { st in
                for i in 0 ..< n {
                    if i & (internCheckInterval - 1) == internCheckInterval - 1 && cancellation.isCancelled {
                        (buffer.baseAddress! + i).initialize(repeating: 0, count: n - i)
                        break
                    }
                    let key = lineKey(p, Int(st[i]), Int(st[i + 1]), ws)
                    buffer[i] = interner.intern(p + key.start, key.end - key.start)
                }
            }
            initialized = n
        }
    }

    /// Matches between two id sequences: common prefix and suffix, unique
    /// line anchors, then Myers on every gap between anchors. `idCount` is
    /// one more than the largest id.
    static func lineMatches(_ a: UnsafePointer<Int32>, _ nA: Int, _ b: UnsafePointer<Int32>, _ nB: Int,
                            idCount: Int, minCost: Int,
                            cancellation: CancellationFlag?) -> ([Int32], [Int32]) {
        let output = Myers(minCost: minCost, cancellation: cancellation)
        // a. Common prefix and suffix.
        var prefix = 0
        while prefix < nA && prefix < nB && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < nA - prefix && suffix < nB - prefix && a[nA - 1 - suffix] == b[nB - 1 - suffix] {
            suffix += 1
        }
        output.matchesA.reserveCapacity(min(nA, nB))
        output.matchesB.reserveCapacity(min(nA, nB))
        for i in 0 ..< prefix {
            output.matchesA.append(Int32(i))
            output.matchesB.append(Int32(i))
        }
        let endA = nA - suffix, endB = nB - suffix

        // b. Occurrence counts over the middle, saturating at 2: the low two
        //    bits count A, the next two bits count B. 5 means "once on each
        //    side".
        var counts = [UInt8](repeating: 0, count: idCount)
        // Each pass below is linear; the token is polled between passes (an
        // early return leaves meaningless matches, which the caller drops).
        if cancellation.isCancelled { return ([], []) }
        counts.withUnsafeMutableBufferPointer { c in
            for i in prefix ..< endA {
                let t = Int(a[i])
                if c[t] & 3 < 2 { c[t] += 1 }
            }
            for i in prefix ..< endB {
                let t = Int(b[i])
                if c[t] >> 2 < 2 { c[t] += 4 }
            }
        }
        if cancellation.isCancelled { return ([], []) }
        var uniqueA: [Int32] = [], uniqueB: [Int32] = []
        var uniqueIdsA: [Int32] = [], uniqueIdsB: [Int32] = []
        counts.withUnsafeBufferPointer { c in
            for i in prefix ..< endA where c[Int(a[i])] == 5 {
                uniqueA.append(Int32(i))
                uniqueIdsA.append(a[i])
            }
            for i in prefix ..< endB where c[Int(b[i])] == 5 {
                uniqueB.append(Int32(i))
                uniqueIdsB.append(b[i])
            }
        }

        if cancellation.isCancelled { return ([], []) }
        // c. Myers over the unique lines only gives the anchors.
        let anchors = Myers(minCost: minCost, cancellation: cancellation)
        uniqueIdsA.withUnsafeBufferPointer { x in
            uniqueIdsB.withUnsafeBufferPointer { y in
                if let xa = x.baseAddress, let yb = y.baseAddress {
                    anchors.diff(xa, 0, x.count, yb, 0, y.count)
                }
            }
        }

        // d. Myers on every gap between anchors. In big gaps, lines that never
        //    occur on the other side are dropped first: they cannot match, so
        //    the LCS is unchanged, but D shrinks, and a block of completely
        //    different lines costs nothing instead of O(N*D).
        let gapMyers = Myers(minCost: minCost, cancellation: cancellation)
        var keptIdsA: [Int32] = [], keptIdsB: [Int32] = []
        var keptA: [Int32] = [], keptB: [Int32] = []
        func gap(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) {
            if cancellation.isCancelled { return }
            if x1 - x0 < 32 || y1 - y0 < 32 {
                output.diff(a, x0, x1, b, y0, y1)
                return
            }
            keptIdsA.removeAll(keepingCapacity: true)
            keptIdsB.removeAll(keepingCapacity: true)
            keptA.removeAll(keepingCapacity: true)
            keptB.removeAll(keepingCapacity: true)
            counts.withUnsafeBufferPointer { c in
                for i in x0 ..< x1 where c[Int(a[i])] >> 2 != 0 {
                    keptIdsA.append(a[i])
                    keptA.append(Int32(i))
                }
                for i in y0 ..< y1 where c[Int(b[i])] & 3 != 0 {
                    keptIdsB.append(b[i])
                    keptB.append(Int32(i))
                }
            }
            if keptIdsA.isEmpty || keptIdsB.isEmpty || cancellation.isCancelled { return }
            gapMyers.reset()
            keptIdsA.withUnsafeBufferPointer { x in
                keptIdsB.withUnsafeBufferPointer { y in
                    gapMyers.diff(x.baseAddress!, 0, x.count, y.baseAddress!, 0, y.count)
                }
            }
            for m in 0 ..< gapMyers.matchesA.count {
                output.matchesA.append(keptA[Int(gapMyers.matchesA[m])])
                output.matchesB.append(keptB[Int(gapMyers.matchesB[m])])
            }
        }
        var cursorA = prefix, cursorB = prefix
        for m in 0 ..< anchors.matchesA.count {
            let anchorA = Int(uniqueA[Int(anchors.matchesA[m])])
            let anchorB = Int(uniqueB[Int(anchors.matchesB[m])])
            gap(cursorA, anchorA, cursorB, anchorB)
            output.matchesA.append(Int32(anchorA))
            output.matchesB.append(Int32(anchorB))
            cursorA = anchorA + 1
            cursorB = anchorB + 1
        }
        gap(cursorA, endA, cursorB, endB)
        for i in 0 ..< suffix {
            output.matchesA.append(Int32(endA + i))
            output.matchesB.append(Int32(endB + i))
        }
        return (output.matchesA, output.matchesB)
    }
}

/// A mixed block waiting for word refinement.
struct RefineJob: Sendable {
    var a: Range<Int>
    var b: Range<Int>
}

/// True when the buffer ends with a line terminator (LF, CRLF or lone CR).
/// An empty buffer has no final newline.
func hasFinalNewline(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
    guard let last = p.last else { return false }
    return last == 10 || last == 13
}

/// Number of active CPUs, without Foundation.
enum CPU {
    static let activeCount: Int = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.activecpu", &n, &size, nil, 0) == 0 else { return 1 }
        return max(Int(n), 1)
    }()
}

/// Read-only inputs shared by refinement workers.
///
/// `@unchecked Sendable` because of the two raw pointers: they borrow the
/// caller's input buffers, which `TextDiff.diff` keeps alive until every
/// worker has returned (`concurrentPerform` is synchronous), and nothing
/// writes through them.
struct RefineContext: @unchecked Sendable {
    let pa: UnsafePointer<UInt8>
    let pb: UnsafePointer<UInt8>
    let startsA: [Int32]
    let startsB: [Int32]
    let ws: Int
    let maxTokens: Int
    let minCost: Int
    let prePairBytes: Int
    let cancellation: CancellationFlag?

    /// Bytes of lines `ar` in A plus lines `br` in B.
    func byteCount(_ ar: Range<Int>, _ br: Range<Int>) -> Int {
        Int(startsA[ar.upperBound] - startsA[ar.lowerBound])
            + Int(startsB[br.upperBound] - startsB[br.lowerBound])
    }
}

/// One result slot per refinement job.
///
/// `@unchecked Sendable` because the slots are raw memory written from
/// several workers. That is race-free: each slot is written by exactly one
/// worker, and read only after `concurrentPerform` has returned.
final class ResultBox: @unchecked Sendable {
    private let slots: UnsafeMutablePointer<[DiffBlock]>
    private let count: Int

    init(count: Int) {
        self.count = count
        slots = .allocate(capacity: max(count, 1))
        slots.initialize(repeating: [], count: count)
    }

    deinit {
        slots.deinitialize(count: count)
        slots.deallocate()
    }

    func put(_ i: Int, _ blocks: [DiffBlock]) { slots[i] = blocks }

    func take(_ i: Int) -> [DiffBlock] {
        let blocks = slots[i]
        slots[i] = []
        return blocks
    }
}
