// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismTestSupport

@Suite struct CorpusTests {
    @Test func rootContainsPackageManifest() {
        let manifest = Corpus.root.appending(path: "Package.swift")
        #expect(FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)))
    }

    @Test(arguments: [
        "text/a.swift", "text/b.swift", "text/big_a.txt", "text/big_b.txt",
        "text/slider_a.groovy", "text/slider_b.groovy",
        "folders/left/src/main.swift", "folders/right/src/main.swift",
        "repo-src/1-init/main.swift",
    ])
    func fixtureExists(_ relative: String) {
        let url = Corpus.fixture(relative)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                "missing fixture \(relative)")
    }

    @Test func bigFixturesHaveExpectedLineCounts() throws {
        #expect(try lineCount(Corpus.fixture("text/big_a.txt")) == 100_000)
        #expect(try lineCount(Corpus.fixture("text/big_b.txt")) == 100_099)
    }

    @Test func committedSelfTestGoldenMatches() {
        let result = Golden.check("Prism golden harness self-test\nline two\n",
                                  against: "harness-selftest.txt")
        #expect(result.passed, "\(result.message)")
    }

    private func lineCount(_ url: URL) throws -> Int {
        try Data(contentsOf: url).reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }
}

@Suite struct GoldenHarnessTests {
    private let update = [Golden.updateVariable: "1"]
    private let compare: [String: String] = [:]

    @Test func roundTripWritesThenMatches() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let text = "alpha\nbeta\n"

        #expect(Golden.check(text, against: "nested/case.txt", in: dir.url, environment: update) == .updated)
        let written = try String(contentsOf: dir.url.appending(path: "nested/case.txt"), encoding: .utf8)
        #expect(written == text)
        #expect(Golden.check(text, against: "nested/case.txt", in: dir.url, environment: compare) == .matched)
    }

    @Test func alteredOutputFailsWithFirstDifference() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        _ = Golden.check("one\ntwo\nthree\n", against: "case.txt", in: dir.url, environment: update)

        let result = Golden.check("one\nTWO\nthree\n", against: "case.txt", in: dir.url, environment: compare)
        #expect(!result.passed)
        #expect(result.message.contains("line 2"))
        #expect(result.message.contains("-two"))
        #expect(result.message.contains("+TWO"))
        #expect(result.message.contains(Golden.updateVariable))
    }

    @Test func updateModeRewritesAStaleGolden() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        _ = Golden.check("old\n", against: "case.txt", in: dir.url, environment: update)
        #expect(!Golden.check("new\n", against: "case.txt", in: dir.url, environment: compare).passed)

        #expect(Golden.check("new\n", against: "case.txt", in: dir.url, environment: update) == .updated)
        #expect(Golden.check("new\n", against: "case.txt", in: dir.url, environment: compare) == .matched)
    }

    @Test func updateModeIsOnlyEnabledByOne() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let result = Golden.check("x\n", against: "case.txt", in: dir.url,
                                  environment: [Golden.updateVariable: "0"])
        #expect(!result.passed)
        #expect(result.message.contains("missing"))
        #expect(!FileManager.default.fileExists(
            atPath: dir.url.appending(path: "case.txt").path(percentEncoded: false)))
    }

    @Test func missingTrailingNewlineIsReported() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        _ = Golden.check("a\nb\n", against: "case.txt", in: dir.url, environment: update)
        let result = Golden.check("a\nb", against: "case.txt", in: dir.url, environment: compare)
        #expect(result.message.contains("line 2"))
        #expect(result.message.contains("no newline at end of file"))
    }

    @Test func extraLinesAreReported() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        _ = Golden.check("a\n", against: "case.txt", in: dir.url, environment: update)
        let result = Golden.check("a\nb\n", against: "case.txt", in: dir.url, environment: compare)
        #expect(result.message.contains("line 2"))
        #expect(result.message.contains("-<end of file>"))
        #expect(result.message.contains("+b"))
    }

    @Test func lineEndingChangeIsADifference() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        _ = Golden.check("a\n", against: "case.txt", in: dir.url, environment: update)
        let result = Golden.check("a\r\n", against: "case.txt", in: dir.url, environment: compare)
        #expect(!result.passed)
        #expect(result.message.contains("\\r\\n"))
    }

    @Test(arguments: ["", "/abs.txt", "../escape.txt", "a/../../b.txt"])
    func rejectsUnsafeNames(_ name: String) throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let result = Golden.check("x", against: name, in: dir.url, environment: update)
        #expect(!result.passed)
        #expect(result.message.contains("invalid golden name"))
    }
}
