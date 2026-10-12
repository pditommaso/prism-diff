// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
import DiffCore
import Dispatch
import Foundation
import PrismTestSupport
import Testing

@Suite struct CancellationTests {
    /// Options that make a fully-different input expensive on purpose: no
    /// refinement valve, exact Myers and no pre-pairing, so the word-level
    /// alignment of the whole block runs for seconds unless it is cancelled.
    static let slow = DiffOptions(parallel: false, maxRefineTokens: 0, myersMinCost: 0, prePairBytes: 0)

    /// 20k lines on each side, no line in common, but sharing many words.
    static func synthetic() -> ([UInt8], [UInt8]) {
        var rng = SplitMix64(seed: 2026)
        let words = ["alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta", "iota", "kappa"]
        func side(_ prefix: String) -> [UInt8] {
            var text = ""
            for i in 0 ..< 20_000 {
                text += "\(prefix)\(i)"
                for _ in 0 ..< 8 { text += " " + words[Int(rng.next() % UInt64(words.count))] }
                text += "\n"
            }
            return Array(text.utf8)
        }
        return (side("a"), side("b"))
    }

    static func milliseconds(_ from: DispatchTime, _ to: DispatchTime) -> Double {
        Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000
    }

    /// `cancelOnce`, repeated up to `attempts` times while the latency is
    /// over budget; returns the best attempt. The debug-build tests share the
    /// CPU with every other suite running in parallel, and a descheduled
    /// worker thread can miss the budget through no fault of the checkpoint
    /// spacing. The release bench measures the latency on a quiet machine.
    static func cancelMidDiff(_ a: [UInt8], _ b: [UInt8], options: DiffOptions, delayMs: Int = 100,
                              attempts: Int = 3) -> (Result<TextDiffResult, DiffError>, Double, Bool) {
        var best = cancelOnce(a, b, options: options, delayMs: delayMs)
        for _ in 1 ..< attempts where !best.2 && best.1 > 50 {
            let next = cancelOnce(a, b, options: options, delayMs: delayMs)
            if !next.2 && next.1 < best.1 { best = next }
        }
        return best
    }

    /// Starts the diff on another thread, cancels it after `delayMs`, and
    /// returns the outcome with the time from cancel() to the return.
    static func cancelOnce(_ a: [UInt8], _ b: [UInt8], options: DiffOptions,
                           delayMs: Int = 100) -> (Result<TextDiffResult, DiffError>, Double, Bool) {
        let flag = CancellationFlag()
        var options = options
        options.cancellation = flag
        let run = options
        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(Result(catching: { () throws(DiffError) in try TextDiff.cancellableDiff(a, b, options: run) }),
                    at: DispatchTime.now())
            done.signal()
        }
        let finishedEarly = done.wait(timeout: .now() + .milliseconds(delayMs)) == .success
        let cancelledAt = DispatchTime.now()
        flag.cancel()
        done.wait()
        let (outcome, returnedAt) = box.get()
        let latency = finishedEarly ? 0 : milliseconds(cancelledAt, returnedAt)
        print("cancel latency: \(finishedEarly ? "finished before cancel" : "\(latency) ms")")
        return (outcome, latency, finishedEarly)
    }

    @Test func cancellingASyntheticFullyDifferentDiffReturnsWithin50ms() {
        let (a, b) = Self.synthetic()
        let (outcome, latency, finishedEarly) = Self.cancelMidDiff(a, b, options: Self.slow)
        #expect(!finishedEarly, "the diff must still be running when it is cancelled")
        // Switch instead of #expect(throws:): swift-testing reflects over the
        // captured typed-throws Result and has crashed doing so.
        switch outcome {
        case .success: Issue.record("diff finished despite cancel()")
        case .failure(let error): #expect(error == .cancelled)
        }
        #expect(latency <= 50, "returned \(latency) ms after cancel()")
    }

    @Test func cancellingTheGeneratedDiff20kReturnsWithin50ms() throws {
        let directory = Corpus.generatedDirectory
        let pathA = directory.appending(path: "diff20k_a.txt"), pathB = directory.appending(path: "diff20k_b.txt")
        guard let a = try? Data(contentsOf: pathA), let b = try? Data(contentsOf: pathB) else {
            print("skipping: Tests/corpus/generated is absent (run Tests/corpus/scripts/generate.py); "
                  + "the release bench covers it")
            return
        }
        let (outcome, latency, finishedEarly) = Self.cancelMidDiff([UInt8](a), [UInt8](b), options: Self.slow)
        #expect(!finishedEarly, "the diff must still be running when it is cancelled")
        expectCancelled(outcome)
        #expect(latency <= 50, "returned \(latency) ms after cancel()")
    }

    /// `lines` lines on each side, no line in common, built as bytes so a
    /// debug build makes 300k lines quickly.
    static func disjoint(lines: Int) -> ([UInt8], [UInt8]) {
        let words: [[UInt8]] = ["alpha", "beta", "gamma", "delta", "eps", "zeta"].map { Array($0.utf8) }
        func side(_ prefix: UInt8, _ seed: UInt64) -> [UInt8] {
            var rng = SplitMix64(seed: seed)
            var text = [UInt8]()
            text.reserveCapacity(lines * 48)
            for i in 0 ..< lines {
                text.append(prefix)
                text += Array(String(i).utf8)
                for _ in 0 ..< 6 {
                    text.append(32)
                    text += words[Int(rng.next() % UInt64(words.count))]
                }
                text.append(10)
            }
            return text
        }
        return (side(97, 1), side(98, 2))
    }

    @Test(arguments: [50, 150])
    func cancellingAProductionDiffOfA300kLineDisjointPairReturnsWithin50ms(delayMs: Int) {
        // Production options: the whole input is one mixed block, which the
        // refinement valve rejects, so the time goes into tokenizing it and
        // that must poll the token.
        let (a, b) = Self.disjoint(lines: 300_000)
        let (outcome, latency, finishedEarly) = Self.cancelMidDiff(a, b, options: DiffOptions(), delayMs: delayMs)
        if finishedEarly {
            #expect((try? outcome.get())?.changeCount == 2)
        } else {
            expectCancelled(outcome)
            #expect(latency <= 50, "returned \(latency) ms after cancel()")
        }
    }

    @Test func cancellingParallelRefinementReturnsWithin50ms() {
        // Many independent mixed blocks, so refinement fans out to workers.
        var a = "", b = ""
        for block in 0 ..< 400 {
            a += "anchor \(block)\n"
            b += "anchor \(block)\n"
            for line in 0 ..< 40 {
                a += "left \(block) \(line) " + String(repeating: "x y ", count: 30) + "\n"
                b += "right \(block) \(line) " + String(repeating: "y x ", count: 30) + "\n"
            }
        }
        var options = Self.slow
        options.parallel = true
        let (outcome, latency, finishedEarly) = Self.cancelMidDiff(Array(a.utf8), Array(b.utf8),
                                                                   options: options, delayMs: 50)
        if finishedEarly {
            // A fast machine may finish first; the result must then be whole.
            #expect((try? outcome.get()) != nil)
        } else {
            expectCancelled(outcome)
            #expect(latency <= 50, "returned \(latency) ms after cancel()")
        }
    }

    /// `lines` lines of `width` punctuation bytes, every byte a token and
    /// every line different between the sides.
    static func punctuation(lines: Int, width: Int) -> ([UInt8], [UInt8]) {
        let marks = Array(".,;:!?-+*/=<>()[]{}".utf8)
        func side(_ seed: UInt64) -> [UInt8] {
            var rng = SplitMix64(seed: seed)
            var text = [UInt8]()
            text.reserveCapacity(lines * (width + 1))
            for _ in 0 ..< lines {
                for _ in 0 ..< width { text.append(marks[Int(rng.next() % UInt64(marks.count))]) }
                text.append(10)
            }
            return text
        }
        return (side(11), side(12))
    }

    @Test func cancellingTheTokenizingOfOneLongLinePairReturnsWithin50ms() {
        // One line of 4 MB per side: millions of tokens in a single
        // tokenizeLine call, so the poll must happen inside the line.
        let (a, b) = Self.punctuation(lines: 1, width: 4 << 20)
        let (outcome, latency, finishedEarly) = Self.cancelMidDiff(a, b, options: DiffOptions(parallel: false),
                                                                   delayMs: 50)
        if finishedEarly {
            #expect((try? outcome.get()) != nil)
        } else {
            expectCancelled(outcome)
            #expect(latency <= 50, "returned \(latency) ms after cancel()")
        }
    }

    @Test func cancellingABlockOfAFewThousandLongLinesReturnsWithin50ms() {
        // Fewer lines than one per-line poll interval, each with thousands
        // of tokens, and no refinement valve: the whole block is tokenized.
        let (a, b) = Self.punctuation(lines: 2000, width: 2000)
        let (outcome, latency, finishedEarly) = Self.cancelMidDiff(
            a, b, options: DiffOptions(parallel: false, maxRefineTokens: 0), delayMs: 50)
        if finishedEarly {
            #expect((try? outcome.get()) != nil)
        } else {
            expectCancelled(outcome)
            #expect(latency <= 50, "returned \(latency) ms after cancel()")
        }
    }

    @Test func preCancelledTokenReturnsImmediately() {
        let (a, b) = Self.synthetic()
        let flag = CancellationFlag()
        flag.cancel()
        var options = Self.slow
        options.cancellation = flag
        let start = DispatchTime.now()
        #expect(throws: DiffError.cancelled) { try TextDiff.cancellableDiff(a, b, options: options) }
        #expect(Self.milliseconds(start, DispatchTime.now()) < 5)
    }

    @Test func uncancelledTokenGivesTheSameResultAsDiff() throws {
        let a = try Fixtures.bytes("text/a.swift"), b = try Fixtures.bytes("text/b.swift")
        let options = DiffOptions(cancellation: CancellationFlag())
        #expect(try TextDiff.cancellableDiff(a, b, options: options) == TextDiff.diff(a, b))
    }

    @Test func plainDiffIgnoresTheToken() {
        let flag = CancellationFlag()
        flag.cancel()
        let result = TextDiff.diff("a\n".bytes, "b\n".bytes, options: DiffOptions(cancellation: flag))
        #expect(result.changeCount == 1)
    }

    @Test func asyncDiffCompletes() async throws {
        let a = try Fixtures.bytes("text/a.swift"), b = try Fixtures.bytes("text/b.swift")
        let result = try await TextDiff.asyncDiff(a, b)
        #expect(result == TextDiff.diff(a, b))
    }

    @Test func cancellingTheTaskCancelsAnAsyncDiff() async {
        let (a, b) = Self.synthetic()
        let task = Task { () throws(DiffError) -> TextDiffResult in
            try await TextDiff.asyncDiff(a, b, options: Self.slow)
        }
        try? await Task.sleep(for: .milliseconds(100))
        let cancelledAt = DispatchTime.now()
        task.cancel()
        let outcome = await task.result
        let latency = Self.milliseconds(cancelledAt, DispatchTime.now())
        expectCancelled(outcome)
        #expect(latency <= 50, "returned \(latency) ms after cancel()")
    }
}

/// Hands the outcome from the diff thread to the test thread. The semaphore
/// orders the write before the read; the lock keeps the checker satisfied.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<TextDiffResult, DiffError> = .failure(.cancelled)
    private var time = DispatchTime.now()

    func set(_ outcome: Result<TextDiffResult, DiffError>, at time: DispatchTime) {
        lock.withLock {
            self.outcome = outcome
            self.time = time
        }
    }

    func get() -> (Result<TextDiffResult, DiffError>, DispatchTime) {
        lock.withLock { (outcome, time) }
    }
}

/// Checks a cancelled outcome with a switch. `#expect(throws:)` over a captured
/// typed-throws Result makes swift-testing reflect on it, which intermittently
/// crashes in the runtime (swift_projectBox).
func expectCancelled<E: Error>(_ outcome: Result<TextDiffResult, E>, sourceLocation: SourceLocation = #_sourceLocation) {
    switch outcome {
    case .success: Issue.record("diff finished despite cancellation", sourceLocation: sourceLocation)
    case .failure(let error): #expect((error as? DiffError) == .cancelled, sourceLocation: sourceLocation)
    }
}
