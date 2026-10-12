// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
import DiffCore
import Foundation
import PrismTestSupport
import Testing

/// Line-hunk counts against `git diff --no-index --patience -U0` on the
/// committed fixtures. The release bench (`PrismBench gitcheck`) also covers
/// the generated m1 and diff20k pairs.
@Suite struct GitCrossCheckTests {
    /// git's exit status and stdout, or nil when git cannot be run.
    static func runGit(_ arguments: [String], home: URL) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": home.path(percentEncoded: false),
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        process.currentDirectoryURL = home
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// True when `git --version` runs; the comparison is skipped otherwise.
    static let gitAvailable: Bool = {
        guard let home = try? TemporaryDirectory(prefix: "prism-git-probe") else { return false }
        defer { home.remove() }
        return runGit(["--version"], home: home.url)?.0 == 0
    }()

    @Test(.enabled(if: gitAvailable, "git is not available"),
          arguments: [("a.swift", "b.swift"), ("big_a.txt", "big_b.txt"), ("slider_a.groovy", "slider_b.groovy")])
    func hunkCountMatchesGitPatience(_ names: (String, String)) throws {
        let home = try TemporaryDirectory(prefix: "prism-git-home")
        defer { home.remove() }
        let pathA = Corpus.fixture("text/\(names.0)"), pathB = Corpus.fixture("text/\(names.1)")
        let result = TextDiff.diff([UInt8](try Data(contentsOf: pathA)), [UInt8](try Data(contentsOf: pathB)))

        let git = try #require(Self.runGit(
            ["diff", "--no-index", "--patience", "-U0", "--no-color", "--no-ext-diff", "--",
             pathA.path(percentEncoded: false), pathB.path(percentEncoded: false)], home: home.url))
        // git diff --no-index exits 1 when the files differ.
        #expect(git.0 == 1, "git exited \(git.0)")
        #expect(LineHunks.count(result) == LineHunks.headerCount(inUnifiedDiff: git.1),
                "\(names.0) vs \(names.1)")
    }

    @Test func adjacentNonEqualBlocksFormOneHunk() {
        let result = TextDiffResult(
            blocks: [
                DiffBlock(kind: .change, a: 0 ..< 1, b: 0 ..< 1),
                DiffBlock(kind: .insert, a: 1 ..< 1, b: 1 ..< 3),
                DiffBlock(kind: .equal, a: 1 ..< 4, b: 3 ..< 6),
                DiffBlock(kind: .delete, a: 4 ..< 5, b: 6 ..< 6),
                DiffBlock(kind: .equal, a: 5 ..< 6, b: 6 ..< 7),
                DiffBlock(kind: .change, a: 6 ..< 7, b: 7 ..< 8),
            ],
            linesA: LineIndex(starts: (0 ... 7).map { Int32($0 * 2) }),
            linesB: LineIndex(starts: (0 ... 8).map { Int32($0 * 2) }),
            aHasFinalNewline: true, bHasFinalNewline: true)
        #expect(LineHunks.count(result) == 3)
    }

    @Test func identicalInputHasNoHunks() {
        let text = Array("one\ntwo\n".utf8)
        #expect(LineHunks.count(TextDiff.diff(text, text)) == 0)
    }

    @Test func headerCountCountsOnlyHunkHeaders() {
        let patch = """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -1 +1 @@
            -@@ not a header
            +@@ also not
            @@ -3,0 +4,2 @@
            +x
            """
        #expect(LineHunks.headerCount(inUnifiedDiff: patch) == 2)
        #expect(LineHunks.headerCount(inUnifiedDiff: "") == 0)
    }
}
