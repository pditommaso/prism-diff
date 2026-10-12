// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation

/// `perf`: median in-process engine time per case against its budget.
enum PerfBench {
    struct Case {
        let pair: BenchPair
        let options: DiffOptions
        /// Budget at scale 1, multiplied by `--scale`.
        let budgetMs: Double
        /// A bound that holds whatever the scale, or nil.
        let absoluteMs: Double?
        /// Extra `key=value` fields identifying the case.
        let label: String
    }

    /// An absolute bound on the big pair that holds on any machine (the M1
    /// budget), so it ignores `--scale`.
    static let bigAbsoluteMs = 130.0

    static func cases(corpus: URL) -> [Case] {
        [
            Case(pair: .fixture("big", "big_a.txt", "big_b.txt", in: corpus), options: DiffOptions(),
                 budgetMs: 40, absoluteMs: bigAbsoluteMs, label: "big"),
            Case(pair: .generated("m1", in: corpus), options: DiffOptions(),
                 budgetMs: 400, absoluteMs: nil, label: "m1"),
            Case(pair: .generated("crlf", in: corpus), options: DiffOptions(whitespace: .exact),
                 budgetMs: 300, absoluteMs: nil, label: "crlf"),
            Case(pair: .generated("diff20k", in: corpus), options: DiffOptions(),
                 budgetMs: 2000, absoluteMs: nil, label: "diff20k"),
        ]
    }

    static func run(corpus: URL, scale: Double, repeats: Int, report: BenchReport) {
        report.info(["bench": "perf", "scale": String(scale), "repeat": String(repeats)])
        for item in cases(corpus: corpus) {
            let ws = String(item.options.whitespace.rawValue)
            if let reason = item.pair.missingReason {
                report.record(false, "\(item.label): \(reason)",
                              fields: ["case": item.label, "ws": ws, "missing": "1"])
                continue
            }
            let input: MappedPair
            do {
                input = try item.pair.load()
            } catch {
                report.record(false, "\(item.label): cannot read input: \(error.localizedDescription)",
                              fields: ["case": item.label, "ws": ws, "missing": "1"])
                continue
            }
            let (median, changes) = measure(input, item.options, repeats: repeats)
            var limit = item.budgetMs * scale
            if let absolute = item.absoluteMs { limit = min(limit, absolute) }
            let passed = median <= limit
            let absoluteNote = item.absoluteMs.map { ", absolute \(formatMs($0)) ms" } ?? ""
            report.record(passed,
                          "\(item.label) ws=\(ws): median \(formatMs(median)) ms, limit \(formatMs(limit)) ms "
                              + "(budget \(formatMs(item.budgetMs)) ms x \(scale)\(absoluteNote)), \(changes) changes",
                          fields: ["case": item.label, "ws": ws, "median_ms": formatMs(median),
                                   "limit_ms": formatMs(limit), "budget_ms": formatMs(item.budgetMs),
                                   "changes": String(changes)])
        }
    }

    /// One warm-up run, then the median of `repeats` timed runs. Only the
    /// engine call is timed; the inputs are already mapped.
    static func measure(_ input: MappedPair, _ options: DiffOptions, repeats: Int) -> (Double, Int) {
        let changes = input.diff(options).changeCount
        var times: [Double] = []
        for _ in 0 ..< max(1, repeats) {
            let start = nowMs()
            let result = input.diff(options)
            times.append(nowMs() - start)
            withExtendedLifetime(result) {}
        }
        return (median(times), changes)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
