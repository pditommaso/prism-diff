// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation
import PrismProtocol
import PrismTestSupport
import Testing
import TextImport
@testable import PrismTool

/// `prism diff`, run in process through `PrismCommand.run`.
@Suite struct DiffCommandTests {

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func prism(_ args: [String], environment: [String: String] = [:]) -> Output {
        let out = CapturedOutput()
        let err = CapturedOutput()
        let status = PrismCommand.run(args, programName: "prism", environment: environment,
                                      stdout: out.sink, stderr: err.sink)
        return Output(status: status, stdout: out.text, stderr: err.text)
    }

    static let a = path("text/a.swift")
    static let b = path("text/b.swift")

    static func path(_ fixture: String) -> String {
        Corpus.fixture(fixture).path(percentEncoded: false)
    }

    /// Output with the checkout location removed, so goldens hold the
    /// repository-relative paths an invocation from the root would print.
    static func relative(_ text: String) -> String {
        text.replacingOccurrences(of: Corpus.root.path(percentEncoded: false), with: "")
    }

    /// Writes `files` into a fresh temporary directory and runs `body`.
    static func withFiles(_ files: [String: [UInt8]], _ body: (URL) throws -> Void) throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        for (name, bytes) in files {
            try Data(bytes).write(to: dir.url.appending(path: name))
        }
        try body(dir.url)
    }

    // MARK: goldens

    @Test func jsonMatchesTheGolden() {
        let result = Self.prism(["diff", Self.a, Self.b, "--json"])
        #expect(result.status == 1)
        #expect(result.stderr.isEmpty)
        let golden = Golden.check(result.stdout, against: "diff-a-b.json")
        #expect(golden.passed, "\(golden.message)")
        #expect(result.stdout.contains("\"changes\":8,"))
        // The second difference adds " a friendly " to the doc comment.
        #expect(result.stdout.contains("{\"aLine\":2,\"bLine\":3,\"a\":[13,13],\"b\":[13,24],\"aUTF16\":[13,13],\"bUTF16\":[13,24]}"))
        #expect(!result.stdout.contains("a.swift"), "the JSON names no files")
    }

    @Test func sliderInsertIsPlacedAfterTheBlankLine() {
        let result = Self.prism(["diff", "--json", Self.path("text/slider_a.groovy"), Self.path("text/slider_b.groovy")])
        #expect(result.status == 1)
        let golden = Golden.check(result.stdout, against: "diff-slider.json")
        #expect(golden.passed, "\(golden.message)")
        #expect(result.stdout.contains("{\"kind\":\"insert\",\"a\":[10,10],\"b\":[10,17]}"))
        #expect(result.stdout.contains("\"changes\":1,"))
    }

    @Test func unifiedIsTheDefaultAndMatchesTheGolden() {
        let plain = Self.prism(["diff", Self.a, Self.b])
        let explicit = Self.prism(["diff", "--unified", Self.a, Self.b])
        #expect(plain.status == 1)
        #expect(plain.stdout == explicit.stdout)
        let golden = Golden.check(Self.relative(plain.stdout), against: "diff-a-b.unified.txt")
        #expect(golden.passed, "\(golden.message)")
        #expect(plain.stdout.contains("\n@@ -1,21 +1,21 @@\n"))
    }

    @Test func sideBySideMatchesTheGolden() {
        let result = Self.prism(["diff", "--side-by-side", "--width", "160", Self.a, Self.b])
        #expect(result.status == 1)
        let golden = Golden.check(result.stdout, against: "diff-a-b.side-by-side.txt")
        #expect(golden.passed, "\(golden.message)")
        // The default width is 160 when COLUMNS is not set.
        #expect(Self.prism(["diff", "--side-by-side", Self.a, Self.b]).stdout == result.stdout)
    }

    // MARK: exit status

    @Test func identicalFilesExitZeroWithNoOutput() {
        let result = Self.prism(["diff", Self.a, Self.a])
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        let json = Self.prism(["diff", "--json", Self.a, Self.a])
        #expect(json.status == 0)
        #expect(json.stdout.contains("\"changes\":0,"))
    }

    @Test func missingFileIsTrouble() {
        let result = Self.prism(["diff", Self.a, Self.path("text/no-such-file")])
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr == "prism diff: \(Self.path("text/no-such-file")): No such file or directory\n")
    }

    @Test func directoryIsTrouble() {
        let result = Self.prism(["diff", Self.path("text"), Self.a])
        #expect(result.status == 2)
        #expect(result.stderr.hasSuffix(": Is a directory\n"))
    }

    @Test(arguments: [
        ["diff", "--ws", "3", "x", "y"],
        ["diff", "--ws=-1", "x", "y"],
        ["diff", "--ws"],
        ["diff", "--json", "--unified", "x", "y"],
        ["diff", "--side-by-side", "--json", "x", "y"],
        ["diff", "--width", "5", "--side-by-side", "x", "y"],
        ["diff", "--width", "1000000000", "--side-by-side", "x", "y"],
        ["diff", "-", "-"],
        ["diff", "--bogus", "x", "y"],
        ["diff", "x"],
        ["diff", "x", "y", "z"],
        ["diff"],
    ])
    func usageErrorsExitTwo(args: [String]) {
        let result = Self.prism(args)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.hasPrefix("prism diff: "))
        #expect(result.stderr.contains("usage: prism diff "))
        #expect(result.stderr.contains("try 'prism diff --help'"))
    }

    @Test func repeatingAFormatFlagIsAllowed() {
        #expect(Self.prism(["diff", "--json", "--json", Self.a, Self.b]).status == 1)
    }

    @Test func optionsMayFollowAndPrecedeTheFiles() {
        let before = Self.prism(["diff", "--ws", "1", "--json", Self.a, Self.b])
        let after = Self.prism(["diff", Self.a, Self.b, "--json", "--ws=1"])
        #expect(before.stdout == after.stdout)
        #expect(before.stdout.contains("\"whitespace\":1,"))
    }

    @Test func doubleDashEndsTheOptions() throws {
        try Self.withFiles(["--json": Array("x\n".utf8), "b": Array("y\n".utf8)]) { dir in
            let result = Self.prism(["diff", "--", dir.appending(path: "--json").path, dir.appending(path: "b").path])
            #expect(result.status == 1)
            #expect(result.stdout.contains("-x\n+y\n"))
        }
    }

    // MARK: whitespace

    @Test func ignoringLineEndingsMakesCRLFAndLFEqual() throws {
        let lf = Array("one\ntwo\nthree\n".utf8)
        let crlf = Array("one\r\ntwo\r\nthree\r\n".utf8)
        try Self.withFiles(["lf.txt": lf, "crlf.txt": crlf]) { dir in
            let files = [dir.appending(path: "crlf.txt").path, dir.appending(path: "lf.txt").path]
            let ignored = Self.prism(["diff", "--ws", "1", "--json"] + files)
            #expect(ignored.status == 0)
            #expect(ignored.stdout.contains("\"changes\":0,"))
            #expect(Self.prism(["diff", "--ws", "2"] + files).status == 0)
            let exact = Self.prism(["diff", "--json"] + files)
            #expect(exact.status == 1)
        }
    }

    // MARK: inputs

    @Test func devNullAgainstAFileIsAllInserts() {
        let result = Self.prism(["diff", "--json", "/dev/null", Self.a])
        #expect(result.status == 1)
        #expect(result.stdout == """
            {"format":"prism-diff","version":1,"whitespace":0,"changes":1,"blocks":[
            {"kind":"insert","a":[0,0],"b":[0,21]}
            ]}

            """)
        let unified = Self.prism(["diff", "/dev/null", Self.a])
        #expect(unified.stdout.contains("\n@@ -0,0 +1,21 @@\n+import Foundation\n"))
    }

    @Test func hugeColumnsIsIgnored() {
        let result = Self.prism(["diff", "--side-by-side", Self.a, Self.b], environment: ["COLUMNS": "1000000000"])
        let explicit = Self.prism(["diff", "--side-by-side", "--width", "\(DiffCommand.defaultWidth)", Self.a, Self.b])
        #expect(result.stdout == explicit.stdout)
    }

    @Test func processSubstitutionPathsAreRead() throws {
        // `<(printf 'a\n')` names a pipe under /dev/fd.
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        _ = "a\n".withCString { write(fds[1], $0, 2) }
        close(fds[1])
        defer { close(fds[0]) }
        let result = Self.prism(["diff", "/dev/fd/\(fds[0])", "/dev/null"])
        #expect(result.status == 1)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.hasSuffix("@@ -1 +0,0 @@\n-a\n"))
    }

    /// Unified output that ends in a change followed by a deletion, with no
    /// final newline on B, must still apply with patch(1): every removed
    /// line of a run comes before its added lines.
    @Test(arguments: [
        ("one\ntwo\nthree\n", "one 1\ntwo"),
        ("one\ntwo\nthree", "one 1\ntwo\n"),
        ("a\nb\nc\nd\n", "a\nB\nnew\nd"),
        ("x\n", "y\nz"),
    ])
    func unifiedOutputAppliesWithPatch(a: String, b: String) throws {
        try Self.withFiles(["a": Array(a.utf8), "b": Array(b.utf8)]) { dir in
            let fileA = dir.appending(path: "a").path, fileB = dir.appending(path: "b").path
            let result = Self.prism(["diff", fileA, fileB])
            #expect(result.status == 1)
            let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            // Within the hunk, no '-' line follows a '+' line.
            var sawAdded = false
            for line in lines where !line.hasPrefix("---") && !line.hasPrefix("+++") {
                if line.hasPrefix("+") { sawAdded = true }
                if line.hasPrefix("-") { #expect(!sawAdded, "removed line after an added one:\n\(result.stdout)") }
                if line.hasPrefix(" ") || line.hasPrefix("@@") { sawAdded = false }
            }
            let patchFile = dir.appending(path: "p.diff")
            try Data(result.stdout.utf8).write(to: patchFile)
            let patch = Process()
            patch.executableURL = URL(filePath: "/usr/bin/patch")
            patch.arguments = ["-s", "-i", patchFile.path, fileA]
            patch.standardOutput = FileHandle.nullDevice
            patch.standardError = FileHandle.nullDevice
            try patch.run()
            patch.waitUntilExit()
            #expect(patch.terminationStatus == 0, "patch rejected:\n\(result.stdout)")
            #expect(try Data(contentsOf: URL(filePath: fileA)) == Data(b.utf8))
        }
    }

    @Test func missingFinalNewlineIsMarked() throws {
        try Self.withFiles(["a": Array("same\nold".utf8), "b": Array("same\nnew\n".utf8)]) { dir in
            let result = Self.prism(["diff", dir.appending(path: "a").path, dir.appending(path: "b").path])
            #expect(result.status == 1)
            #expect(result.stdout.hasSuffix("""
                @@ -1,2 +1,2 @@
                 same
                -old
                \\ No newline at end of file
                +new

                """))
        }
    }

    @Test func loneCRLinesGetAnLFInUnifiedOutput() throws {
        try Self.withFiles(["a": Array("x\ry\r".utf8), "b": Array("x\rz\r".utf8)]) { dir in
            let result = Self.prism(["diff", dir.appending(path: "a").path, dir.appending(path: "b").path])
            #expect(result.stdout.hasSuffix("@@ -1,2 +1,2 @@\n x\r\n-y\r\n+z\r\n"))
        }
    }

    @Test func utf16ColumnsCountSurrogatePairs() throws {
        // "café 😀 " is 11 bytes but 8 UTF-16 units.
        try Self.withFiles(["a": Array("café 😀 old\n".utf8), "b": Array("café 😀 new\n".utf8)]) { dir in
            let result = Self.prism(["diff", "--json", dir.appending(path: "a").path, dir.appending(path: "b").path])
            #expect(result.stdout.contains("\"a\":[11,14],\"b\":[11,14],\"aUTF16\":[8,11],\"bUTF16\":[8,11]"))
        }
    }

    @Test func utf16CursorAgreesWithTheEngineAcrossHunksOfALine() throws {
        // Several hunks on one line, with multi-byte characters in between,
        // so the cursor counts on from the previous hunk. The 0xFF bytes make
        // the files Windows-1252: the engine sees the decoded UTF-8.
        let a: [UInt8] = Array("α one β two ".utf8) + [0xFF, 0x20] + Array("γ three 😀 four\n".utf8)
        let b: [UInt8] = Array("α 1 β 2 ".utf8) + [0xFF, 0x20] + Array("γ 3 😀 4\n".utf8)
        try Self.withFiles(["a": a, "b": b]) { dir in
            let result = Self.prism(["diff", "--json", dir.appending(path: "a").path, dir.appending(path: "b").path])
            let expected = expectedWords(try TextImport.decode(a).utf8, try TextImport.decode(b).utf8)
            #expect(expected.count == 4)
            for word in expected { #expect(result.stdout.contains(word)) }
        }
    }

    /// The words entries computed with the engine's own UTF-16 API.
    func expectedWords(_ a: [UInt8], _ b: [UInt8]) -> [String] {
        let result = TextDiff.diff(a, b)
        return result.blocks.flatMap(\.words).map { hunk in
            let ua = result.utf16Range(of: hunk, side: .a, in: a)
            let ub = result.utf16Range(of: hunk, side: .b, in: b)
            return "\"a\":[\(hunk.a.lowerBound),\(hunk.a.upperBound)],\"b\":[\(hunk.b.lowerBound),\(hunk.b.upperBound)]"
                + ",\"aUTF16\":[\(ua.lowerBound),\(ua.upperBound)],\"bUTF16\":[\(ub.lowerBound),\(ub.upperBound)]"
        }
    }

    // MARK: colour

    @Test(arguments: [[], ["--unified"], ["--side-by-side"], ["--json"]])
    func noEscapesWithoutColor(format: [String]) {
        let result = Self.prism(["diff"] + format + [Self.a, Self.b])
        #expect(!result.stdout.contains("\u{1B}"))
    }

    @Test(arguments: [[], ["--side-by-side"]])
    func colorUsesKindColorsAndReverseVideoForWords(format: [String]) {
        let result = Self.prism(["diff", "--color"] + format + [Self.a, Self.b])
        #expect(result.status == 1)
        #expect(result.stdout.contains("\u{1B}["))
        #expect(result.stdout.contains("\u{1B}[32mimport OSLog"), "insert in green")
        #expect(result.stdout.contains("\u{1B}[31m"), "delete in red")
        #expect(result.stdout.contains("\u{1B}[33m"), "change in yellow")
        #expect(result.stdout.contains("\u{1B}[33m\u{1B}[7ma friendly "), "changed words in reverse video")
        // Stripping the escapes gives the plain output back.
        let plain = Self.prism(["diff"] + format + [Self.a, Self.b]).stdout
        #expect(Self.stripEscapes(result.stdout) == plain)
    }

    @Test func colorIsIgnoredWithJSON() {
        let colored = Self.prism(["diff", "--color", "--json", Self.a, Self.b])
        #expect(colored.stdout == Self.prism(["diff", "--json", Self.a, Self.b]).stdout)
    }

    static func stripEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    // MARK: side-by-side layout

    @Test func widthComesFromColumnsWhenNotGiven() {
        let narrow = Self.prism(["diff", "--side-by-side", Self.a, Self.b], environment: ["COLUMNS": "60"])
        let explicit = Self.prism(["diff", "--side-by-side", "--width", "60", Self.a, Self.b])
        #expect(narrow.stdout == explicit.stdout)
        for line in narrow.stdout.split(separator: "\n") { #expect(line.count <= 60) }
        // A COLUMNS value too small to use falls back to the default.
        let tiny = Self.prism(["diff", "--side-by-side", Self.a, Self.b], environment: ["COLUMNS": "3"])
        #expect(tiny.stdout == Self.prism(["diff", "--side-by-side", Self.a, Self.b]).stdout)
    }

    @Test func sideBySideMarksEveryKindOfRow() throws {
        let a = Array("keep\nremoved line\nsame\nalpha beta\nend\n".utf8)
        let b = Array("keep\nsame\nalpha gamma\nend\nextra\n".utf8)
        try Self.withFiles(["a": a, "b": b]) { dir in
            let result = Self.prism(["diff", "--side-by-side", "--width", "41",
                                     dir.appending(path: "a").path, dir.appending(path: "b").path])
            // Each half is (41 - 3) / 2 = 19 cells: number, space, 17 of text.
            #expect(result.stdout == """
                1 keep                1 keep
                2 removed line      <
                3 same                2 same
                4 alpha beta        | 3 alpha gamma
                5 end                 4 end
                                    > 5 extra

                """)
        }
    }

    @Test func displayTextExpandsTabsAndTruncates() {
        let palette = Palette(enabled: false)
        func render(_ text: String, _ width: Int) -> (String, Int) {
            let bytes = Array(text.utf8)
            let (out, cells) = DisplayText.render(bytes[...], highlights: [], width: width, color: nil, palette: palette)
            return (out, cells)
        }
        #expect(render("a\tb", 20) == ("a       b", 9))
        #expect(render("abcdefghij", 10) == ("abcdefghij", 10))
        #expect(render("abcdefghijk", 10) == ("abcdefghi…", 10))
        #expect(render("x\u{7}y", 10) == ("x?y", 3))
        #expect(render("日本語テキスト", 7) == ("日本語…", 7))
        #expect(render("e\u{301}", 5) == ("e\u{301}", 1))
    }

    // MARK: help

    @Test(arguments: ["-h", "--help"])
    func diffHasItsOwnHelp(flag: String) {
        let result = Self.prism(["diff", flag])
        #expect(result.status == 0)
        #expect(result.stdout.contains("usage: prism diff "))
        for option in ["--ws", "--json", "--unified", "--side-by-side", "--color", "--width", "Exit status"] {
            #expect(result.stdout.contains(option))
        }
    }
}
