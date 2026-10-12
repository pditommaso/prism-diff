// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
import DiffCore
import Foundation
import Testing

/// Seeded random cases checked against the edit-script invariants (see
/// `InvariantChecker`). The default count keeps debug `swift test` fast; set
/// PRISM_PROPERTY_ITERATIONS to run more (each iteration is 6 diffs).
@Suite struct PropertyTests {
    static let iterations: Int = {
        if let text = ProcessInfo.processInfo.environment["PRISM_PROPERTY_ITERATIONS"],
           let value = Int(text), value > 0 {
            return value
        }
        return 300
    }()

    @Test func randomCasesSatisfyEveryInvariant() {
        let report = PropertyRunner.run(iterations: Self.iterations)
        #expect(report.cases == Self.iterations * 6)
        #expect(report.failures == 0, "\(report.failureDetails.joined(separator: "\n"))")
    }

    @Test func runsAreReproducibleFromTheSeed() {
        var first = SplitMix64(seed: 99), second = SplitMix64(seed: 99)
        for iteration in 0 ..< 5 {
            let x = PropertyPass.forcedHeuristics.makeCase(iteration: iteration, &first)
            let y = PropertyPass.forcedHeuristics.makeCase(iteration: iteration, &second)
            #expect(x.a == y.a && x.b == y.b && x.options == y.options)
        }
    }

    @Test func engineKeepsNearlyAllOptimalEqualLines() {
        let report = PropertyRunner.run(iterations: 20, measureOptimality: true)
        #expect(report.failures == 0)
        #expect(report.optimalEqualLines > 0)
        #expect(report.optimality > 0.99)
    }

    @Test func checkerRejectsABrokenScript() {
        let a = "one\ntwo\n".bytes, b = "one\nthree\n".bytes
        var result = TextDiff.diff(a, b)
        #expect(InvariantChecker.violations(of: result, a, b, whitespace: .exact).isEmpty)
        result.blocks[result.blocks.count - 1].words = []
        #expect(!InvariantChecker.violations(of: result, a, b, whitespace: .exact).isEmpty)
        result.blocks.removeLast()
        #expect(!InvariantChecker.violations(of: result, a, b, whitespace: .exact).isEmpty)
    }
}
