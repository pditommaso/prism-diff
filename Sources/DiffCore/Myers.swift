// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

/// Linear-space Myers O(ND) diff ("middle snake" bisection) over dense
/// `Int32` token ids.
///
/// The output is the list of matched index pairs (the LCS) in increasing
/// order. The edit script is implied: between two matches, deletes come
/// first, then inserts. That also gives "merge consecutive like differences"
/// and "deletes before inserts" for free.
///
/// Recursion is replaced by an explicit work stack, and both V arrays live in
/// one buffer reused by every bisection, so a run allocates almost nothing.
///
/// Like xdiff, the search gives up on minimality once the edit distance
/// exceeds a cost limit and splits at the furthest-reaching point found so
/// far. The script stays valid; it may just not be minimal.
final class Myers {
    private var v: UnsafeMutablePointer<Int32>
    private var vCapacity: Int
    private var stack: [Span] = []
    /// Minimum cost limit (0 means exact).
    let minCost: Int
    /// Scale the limit with sqrt(N) (line level) or keep it at `minCost`
    /// (word level, where N can be millions of tokens and minimality matters
    /// less).
    let scaled: Bool
    /// Polled once per bisection and every `cancelCheckInterval` diagonals
    /// inside one. Once it is cancelled, `diff` stops early; its matches are
    /// then a valid but meaningless partial script that callers discard.
    let cancellation: CancellationFlag?
    private var costLimit = Int.max
    /// Matched indices, appended in increasing order.
    var matchesA: [Int32] = []
    var matchesB: [Int32] = []

    /// A pending range pair, or (when `isEqualRun`) a run of `a1` matches
    /// starting at `a0`/`b0` that must be emitted after the ranges before it.
    private struct Span {
        var a0: Int, a1: Int, b0: Int, b1: Int
        var isEqualRun: Bool
    }

    /// Diagonals visited between two polls of the cancellation token.
    static let cancelCheckInterval = 4096

    /// Spans longer than this (both sides together) poll the cancellation
    /// token before their linear prefix and suffix strip.
    static let longSpan = 1 << 16

    init(minCost: Int = 256, scaled: Bool = true, cancellation: CancellationFlag? = nil) {
        self.minCost = minCost
        self.scaled = scaled
        self.cancellation = cancellation
        vCapacity = 64
        v = .allocate(capacity: vCapacity)
    }

    deinit { v.deallocate() }

    func reset() {
        matchesA.removeAll(keepingCapacity: true)
        matchesB.removeAll(keepingCapacity: true)
    }

    /// Appends the matches of `a[a0..<a1]` against `b[b0..<b1]`.
    func diff(_ a: UnsafePointer<Int32>, _ a0: Int, _ a1: Int,
              _ b: UnsafePointer<Int32>, _ b0: Int, _ b1: Int) {
        if minCost <= 0 {
            costLimit = Int.max
        } else if !scaled {
            costLimit = minCost
        } else {
            var root = 1
            while root * root < (a1 - a0) + (b1 - b0) { root += 1 }
            costLimit = max(minCost, root)
        }
        // Work on locals: appending to class properties costs an exclusivity
        // check and a uniqueness check per element.
        var ma: [Int32] = [], mb: [Int32] = [], stack: [Span] = []
        swap(&ma, &matchesA)
        swap(&mb, &matchesB)
        swap(&stack, &self.stack)
        defer {
            swap(&ma, &matchesA)
            swap(&mb, &matchesB)
            swap(&stack, &self.stack)
        }
        stack.append(Span(a0: a0, a1: a1, b0: b0, b1: b1, isEqualRun: false))
        while let span = stack.popLast() {
            if span.isEqualRun {
                for i in 0 ..< span.a1 {
                    ma.append(Int32(span.a0 + i))
                    mb.append(Int32(span.b0 + i))
                }
                continue
            }
            var a0 = span.a0, a1 = span.a1, b0 = span.b0, b1 = span.b1
            // The prefix and suffix strips below are linear: poll before a
            // long one so a cancelled diff never scans millions of tokens.
            if (a1 - a0) + (b1 - b0) > Myers.longSpan && cancellation.isCancelled {
                stack.removeAll(keepingCapacity: true)
                break
            }
            while a0 < a1 && b0 < b1 && a[a0] == b[b0] {
                ma.append(Int32(a0))
                mb.append(Int32(b0))
                a0 += 1
                b0 += 1
            }
            var suffix = 0
            while a1 > a0 && b1 > b0 && a[a1 - 1] == b[b1 - 1] {
                a1 -= 1
                b1 -= 1
                suffix += 1
            }
            if suffix > 0 { stack.append(Span(a0: a1, a1: suffix, b0: b1, b1: 0, isEqualRun: true)) }
            guard a0 < a1 && b0 < b1 else { continue }
            if cancellation.isCancelled {
                stack.removeAll(keepingCapacity: true)
                break
            }
            let n = a1 - a0, m = b1 - b0
            guard let (x, y) = bisect(a + a0, n, b + b0, m),
                  !(x == 0 && y == 0), !(x == n && y == m) else { continue }
            // Pushed in reverse: the lower half is processed first.
            stack.append(Span(a0: a0 + x, a1: a1, b0: b0 + y, b1: b1, isEqualRun: false))
            stack.append(Span(a0: a0, a1: a0 + x, b0: b0, b1: b0 + y, isEqualRun: false))
        }
    }

    /// Finds a point where the forward and reverse D-paths overlap, or the
    /// furthest-reaching point once the cost limit is hit. Returns nil when
    /// the sequences share nothing.
    private func bisect(_ a: UnsafePointer<Int32>, _ n: Int,
                        _ b: UnsafePointer<Int32>, _ m: Int) -> (Int, Int)? {
        let maxD = (n + m + 1) / 2
        // d never exceeds the cost limit, so V only needs +-limit diagonals:
        // O(limit) memory and reset per bisection instead of O(N).
        let span = min(maxD, costLimit) + 1
        let off = span
        let vLength = 2 * span + 2
        if 2 * vLength > vCapacity {
            v.deallocate()
            vCapacity = 2 * vLength
            v = .allocate(capacity: vCapacity)
        }
        let v1 = v, v2 = v + vLength
        v1.update(repeating: -1, count: vLength)
        v2.update(repeating: -1, count: vLength)
        v1[off + 1] = 0
        v2[off + 1] = 0
        let delta = n - m
        let checkForward = delta & 1 != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0
        // Diagonals visited since the last cancellation poll (each d step
        // visits about 2(d + 1)).
        var work = 0
        for d in 0 ..< maxD {
            if d >= costLimit {
                return furthestPoint(v1, v2, off: off, span: span, n: n, m: m)
            }
            work += 2 * (d + 1)
            if work >= Myers.cancelCheckInterval {
                work = 0
                if cancellation.isCancelled { return nil }
            }
            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1o = off + k1
                var x1: Int
                if k1 == -d || (k1 != d && v1[k1o - 1] < v1[k1o + 1]) {
                    x1 = Int(v1[k1o + 1])
                } else {
                    x1 = Int(v1[k1o - 1]) + 1
                }
                var y1 = x1 - k1
                while x1 < n && y1 < m && a[x1] == b[y1] {
                    x1 += 1
                    y1 += 1
                }
                v1[k1o] = Int32(x1)
                if x1 > n {
                    k1end += 2
                } else if y1 > m {
                    k1start += 2
                } else if checkForward {
                    let k2o = off + delta - k1
                    if k2o >= 0 && k2o < vLength && v2[k2o] != -1 {
                        if x1 >= n - Int(v2[k2o]) { return (x1, y1) }
                    }
                }
                k1 += 2
            }
            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2o = off + k2
                var x2: Int
                if k2 == -d || (k2 != d && v2[k2o - 1] < v2[k2o + 1]) {
                    x2 = Int(v2[k2o + 1])
                } else {
                    x2 = Int(v2[k2o - 1]) + 1
                }
                var y2 = x2 - k2
                while x2 < n && y2 < m && a[n - x2 - 1] == b[m - y2 - 1] {
                    x2 += 1
                    y2 += 1
                }
                v2[k2o] = Int32(x2)
                if x2 > n {
                    k2end += 2
                } else if y2 > m {
                    k2start += 2
                } else if !checkForward {
                    let k1o = off + delta - k2
                    if k1o >= 0 && k1o < vLength && v1[k1o] != -1 {
                        let x1 = Int(v1[k1o])
                        let y1 = x1 - (k1o - off)
                        if x1 >= n - x2 { return (x1, y1) }
                    }
                }
                k2 += 2
            }
        }
        return nil
    }

    /// The cost limit was hit: split at the end point (forward or reverse)
    /// that covers the most of both sequences. One O(limit) scan of V, so the
    /// hot loop above carries no extra bookkeeping.
    private func furthestPoint(_ v1: UnsafeMutablePointer<Int32>, _ v2: UnsafeMutablePointer<Int32>,
                               off: Int, span: Int, n: Int, m: Int) -> (Int, Int)? {
        var forward = (x: 0, y: 0, reach: 0), reverse = (x: 0, y: 0, reach: 0)
        for k in -span ... span {
            let x1 = Int(v1[off + k]), y1 = x1 - k
            if x1 >= 0 && x1 <= n && y1 >= 0 && y1 <= m && x1 + y1 > forward.reach {
                forward = (x1, y1, x1 + y1)
            }
            let x2 = Int(v2[off + k]), y2 = x2 - k
            if x2 >= 0 && x2 <= n && y2 >= 0 && y2 <= m && x2 + y2 > reverse.reach {
                reverse = (x2, y2, x2 + y2)
            }
        }
        if forward.reach >= reverse.reach && forward.reach > 0 { return (forward.x, forward.y) }
        if reverse.reach > 0 { return (n - reverse.x, m - reverse.y) }
        return nil
    }
}
