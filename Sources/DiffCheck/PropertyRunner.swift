// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// Outcome of a property run.
public struct PropertyReport: Sendable {
    /// Diffs checked (each also re-run serially and compared).
    public var cases = 0
    /// Diffs with at least one violation.
    public var failures = 0
    /// A description of the first few failures, with what reproduces them.
    public var failureDetails: [String] = []
    /// Equal lines found by the engine, and the LCS optimum, over the cases
    /// measured (only when optimality measurement was requested).
    public var equalLines = 0
    public var optimalEqualLines = 0

    public init() {}

    /// Equal lines kept as a fraction of the optimum (1 when not measured).
    public var optimality: Double {
        optimalEqualLines == 0 ? 1 : Double(equalLines) / Double(optimalEqualLines)
    }
}

/// Runs the seeded property suite: for every iteration, one case per pass
/// (`PropertyPass`), each diffed in all three whitespace modes. So
/// `iterations` iterations check `iterations * 6` diffs.
public enum PropertyRunner {
    public static let defaultSeed: UInt64 = 12345
    static let maxReportedFailures = 5

    public static func run(iterations: Int, seed: UInt64 = defaultSeed,
                           measureOptimality: Bool = false) -> PropertyReport {
        var report = PropertyReport()
        var rng = SplitMix64(seed: seed)
        for pass in PropertyPass.allCases {
            for iteration in 0 ..< iterations {
                let testCase = pass.makeCase(iteration: iteration, &rng)
                for mode in WhitespaceMode.allCases {
                    var options = testCase.options
                    options.whitespace = mode
                    report.cases += 1
                    let problems = InvariantChecker.check(testCase.a, testCase.b, options: options)
                    if !problems.isEmpty {
                        report.failures += 1
                        if report.failureDetails.count < maxReportedFailures {
                            report.failureDetails.append(
                                "seed \(seed) pass \(pass.rawValue) iteration \(iteration) ws=\(mode.rawValue): "
                                    + problems.prefix(3).joined(separator: "; "))
                        }
                    }
                    if measureOptimality && testCase.a.count + testCase.b.count < 60_000 {
                        measure(testCase, options, into: &report)
                    }
                }
            }
        }
        return report
    }

    private static func measure(_ testCase: PropertyCase, _ options: DiffOptions, into report: inout PropertyReport) {
        let result = TextDiff.diff(testCase.a, testCase.b, options: options)
        let ws = options.whitespace.rawValue
        report.equalLines += result.blocks.reduce(0) { $0 + ($1.kind == .equal ? $1.a.count : 0) }
        let keysA = InvariantChecker.referenceLines(testCase.a).map { InvariantChecker.key($0, ws) }
        let keysB = InvariantChecker.referenceLines(testCase.b).map { InvariantChecker.key($0, ws) }
        report.optimalEqualLines += InvariantChecker.lcsLength(keysA, keysB)
    }
}
