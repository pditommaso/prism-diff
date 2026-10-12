// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismTestSupport
import Testing
@testable import PrismApp

/// The headless first-screen bench behind scripts/perf/run.sh.
@MainActor
@Suite struct FirstScreenBenchTests {
    @Test func benchesASmallPairInEveryLayout() {
        let a = Corpus.fixture("text/a.swift").path(percentEncoded: false)
        let b = Corpus.fixture("text/b.swift").path(percentEncoded: false)
        for mode in ["blocks", "fluid", "unified"] {
            #expect(FirstScreenBench.run(["--mode", mode, a, b]) == 0)
        }
        #expect(FirstScreenBench.run(["--wrap", "--width", "600", a, b]) == 0)
    }

    @Test func refusesBadArguments() {
        let a = Corpus.fixture("text/a.swift").path(percentEncoded: false)
        #expect(FirstScreenBench.run([a]) == 2)
        #expect(FirstScreenBench.run(["--mode", "sideways", a, a]) == 2)
        #expect(FirstScreenBench.run(["--width", "10", a, a]) == 2)
        #expect(FirstScreenBench.run(["--frobnicate", a, a]) == 2)
        #expect(FirstScreenBench.run([a, "/nonexistent/prism-perf-missing.txt"]) == 2)
    }

    @Test func versionArgumentMatchesAbout() {
        #expect(PrismAppMain.versionLine() == "Prism \(AboutContent.current.versionLine.dropFirst("Version ".count))")
    }
}
