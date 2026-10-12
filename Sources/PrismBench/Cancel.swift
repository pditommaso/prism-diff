// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Dispatch
import Foundation

/// `cancel`: time from `CancellationFlag.cancel()` to the diff returning.
enum CancelBench {
    /// The cancel budget (spec: a superseded diff must stop within 50 ms).
    static let budgetMs = 50.0
    /// Cancel points after the start. m1 usually finishes in under 100 ms on
    /// an M-series machine, so the 50 ms point makes sure its later stages
    /// are cancelled at least once.
    static let delaysMs = [200, 100, 50, 10]

    /// Options that keep the engine busy for a long time on the corpus
    /// pairs: no refinement valve, exact Myers and no pre-pairing. With the
    /// production defaults diff20k finishes in about 10 ms, before most
    /// cancel points, which would measure nothing. The synthetic disjoint
    /// pairs use the production defaults.
    static let slow = DiffOptions(maxRefineTokens: 0, myersMinCost: 0, prePairBytes: 0)

    /// One input for the cancel bench and the options to diff it with.
    struct Case {
        let name: String
        let options: DiffOptions
        let missingReason: String?
        let load: () throws -> MappedPair
    }

    /// Two files of `lines` lines with no line in common but many shared
    /// words: the whole input is one mixed block. Diffed with the
    /// production options, so the refinement valve and pre-pairing are on
    /// the path being cancelled.
    static func disjoint(lines: Int) -> MappedPair {
        let words = ["alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta", "iota", "kappa"]
        func side(_ prefix: String) -> Data {
            var text = [UInt8]()
            text.reserveCapacity(lines * 48)
            var state: UInt64 = prefix == "a" ? 1 : 2
            for i in 0 ..< lines {
                text += Array("\(prefix)\(i)".utf8)
                for _ in 0 ..< 6 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    text.append(32)
                    text += Array(words[Int(state >> 33) % words.count].utf8)
                }
                text.append(10)
            }
            return Data(text)
        }
        return MappedPair(a: side("a"), b: side("b"))
    }

    /// Two files of `lines` lines of `width` punctuation bytes, every line
    /// different: each byte is a word token, so one line holds thousands of
    /// tokens and the block is far over the refinement valve.
    static func longLines(lines: Int, width: Int) -> MappedPair {
        let marks = Array(".,;:!?-+*/=<>()[]{}".utf8)
        func side(_ seed: UInt64) -> Data {
            var text = [UInt8]()
            text.reserveCapacity(lines * (width + 1))
            var state = seed
            for _ in 0 ..< lines {
                for _ in 0 ..< width {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    text.append(marks[Int(state >> 33) % marks.count])
                }
                text.append(10)
            }
            return Data(text)
        }
        return MappedPair(a: side(1), b: side(2))
    }

    /// One line of about `bytes` bytes of minified JSON per side, with
    /// `edits` values changed at evenly spread places.
    static func oneLine(bytes: Int, edits: Int) -> MappedPair {
        func side(edited: Bool) -> Data {
            var text = [UInt8]()
            text.reserveCapacity(bytes + 64)
            let fields = bytes / 24
            let step = max(fields / max(edits, 1), 1)
            var i = 0
            while text.count < bytes {
                let value = edited && i % step == step / 2 ? "changed" : "value"
                text += Array("{\"key\(i)\":\"\(value)\"},".utf8)
                i += 1
            }
            text.append(10)
            return Data(text)
        }
        return MappedPair(a: side(edited: false), b: side(edited: true))
    }

    static func cases(corpus: URL) -> [Case] {
        var out: [Case] = []
        for name in ["diff20k", "m1"] {
            let pair = BenchPair.generated(name, in: corpus)
            out.append(Case(name: name, options: slow, missingReason: pair.missingReason, load: pair.load))
        }
        for lines in [300_000, 1_000_000] {
            out.append(Case(name: "disjoint\(lines / 1000)k", options: DiffOptions(), missingReason: nil,
                            load: { disjoint(lines: lines) }))
        }
        out.append(Case(name: "longlines2k", options: DiffOptions(), missingReason: nil,
                        load: { longLines(lines: 2000, width: 7000) }))
        // Without the valve the whole block is tokenized: cancellation must
        // land inside the tokenizer, not between lines.
        out.append(Case(name: "longlines2k-novalve", options: DiffOptions(maxRefineTokens: 0), missingReason: nil,
                        load: { longLines(lines: 2000, width: 7000) }))
        out.append(Case(name: "oneline32m", options: DiffOptions(), missingReason: nil,
                        load: { oneLine(bytes: 32 << 20, edits: 5) }))
        out.append(Case(name: "oneline8m", options: DiffOptions(), missingReason: nil,
                        load: { oneLine(bytes: 8 << 20, edits: 5) }))
        return out
    }

    static func run(corpus: URL, report: BenchReport) {
        report.info(["bench": "cancel", "budget_ms": formatMs(budgetMs)])
        for item in cases(corpus: corpus) {
            var input: MappedPair?
            for delay in delaysMs {
                let fields: KeyValuePairs<String, String> = ["case": item.name, "delay_ms": String(delay)]
                if let reason = item.missingReason {
                    report.record(false, "\(item.name) after \(delay) ms: \(reason)",
                                  fields: ["case": item.name, "delay_ms": String(delay), "missing": "1"])
                    continue
                }
                if input == nil { input = try? item.load() }
                guard let input else {
                    report.record(false, "\(item.name): cannot read input", fields: fields)
                    continue
                }
                let pair = item
                let outcome = cancelOnce(input, options: pair.options, delayMs: delay)
                switch outcome {
                case .finishedEarly(let elapsed):
                    // Nothing was left to cancel: the latency is zero by
                    // definition, and the result was whole.
                    report.record(true,
                                  "\(pair.name) after \(delay) ms: finished in \(formatMs(elapsed)) ms, before the cancel",
                                  fields: ["case": pair.name, "delay_ms": String(delay), "latency_ms": "0.00",
                                           "still_running": "0"])
                case .cancelled(let latency):
                    report.record(latency <= budgetMs,
                                  "\(pair.name) after \(delay) ms: returned \(formatMs(latency)) ms after cancel() "
                                      + "(budget \(formatMs(budgetMs)) ms)",
                                  fields: ["case": pair.name, "delay_ms": String(delay),
                                           "latency_ms": formatMs(latency), "still_running": "1"])
                case .completedDespiteCancel(let latency):
                    report.record(false,
                                  "\(pair.name) after \(delay) ms: cancel() was ignored, the diff completed "
                                      + "\(formatMs(latency)) ms later",
                                  fields: ["case": pair.name, "delay_ms": String(delay),
                                           "latency_ms": formatMs(latency), "still_running": "1"])
                }
            }
        }
    }

    enum Outcome {
        case finishedEarly(elapsedMs: Double)
        case cancelled(latencyMs: Double)
        case completedDespiteCancel(latencyMs: Double)
    }

    /// Thread-safe slot for the worker's outcome.
    final class Slot: @unchecked Sendable {
        // Written once by the worker before it signals the semaphore, read
        // by the main thread only after waiting on it: the semaphore orders
        // the accesses.
        var cancelled = false
        var returnedAt = 0.0
    }

    /// Runs the diff on a background thread and cancels it after `delayMs`.
    static func cancelOnce(_ input: MappedPair, options base: DiffOptions, delayMs: Int) -> Outcome {
        let flag = CancellationFlag()
        var options = base
        options.cancellation = flag
        let run = options
        let slot = Slot()
        let done = DispatchSemaphore(value: 0)
        let startedAt = nowMs()
        let worker = Thread {
            do {
                _ = try input.cancellableDiff(run)
            } catch {
                slot.cancelled = true
            }
            slot.returnedAt = nowMs()
            done.signal()
        }
        worker.qualityOfService = .userInitiated
        worker.stackSize = 8 << 20
        worker.start()
        if done.wait(timeout: .now() + .milliseconds(delayMs)) == .success {
            return .finishedEarly(elapsedMs: slot.returnedAt - startedAt)
        }
        let cancelledAt = nowMs()
        flag.cancel()
        done.wait()
        let latency = max(0, slot.returnedAt - cancelledAt)
        return slot.cancelled ? .cancelled(latencyMs: latency) : .completedDespiteCancel(latencyMs: latency)
    }
}
