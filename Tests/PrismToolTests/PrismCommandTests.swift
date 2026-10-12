// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismProtocol
import PrismTestSupport
@testable import PrismTool

private struct Result {
    let status: Int32
    let stdout: String
    let stderr: String
    /// The arguments app-integration mode received; nil when the engine ran.
    let clientArgs: [String]?
}

/// Status the fake app-integration mode returns, so tests can tell it ran.
private let clientStatus: Int32 = 42

/// Runs `prism` in process. App-integration mode is replaced by a fake that
/// records its arguments, so no test ever reaches a real app.
private func prism(_ args: [String], name: String = "prism") -> Result {
    let out = CapturedOutput()
    let err = CapturedOutput()
    var received: [String]?
    let status = PrismCommand.run(args, programName: name, stdout: out.sink, stderr: err.sink) { args, _, _ in
        received = args
        return clientStatus
    }
    return Result(status: status, stdout: out.text, stderr: err.text, clientArgs: received)
}

private func clientArguments(_ args: [String]) -> [String]? {
    prism(args).clientArgs
}

@Test func versionPrintsSemverAndNewline() {
    let result = prism(["--version"])
    #expect(result.status == 0)
    #expect(result.stdout == PrismInfo.version + "\n")
    #expect(PrismInfo.isSemver(String(result.stdout.dropLast())))
    #expect(result.stderr.isEmpty)
}

@Test(arguments: ["-h", "--help"])
func helpListsTheSubcommands(flag: String) throws {
    let result = prism([flag])
    #expect(result.status == 0)
    #expect(result.stdout.contains("usage: prism"))
    for command in ["diff", "sniff", "merge3"] {
        #expect(result.stdout.contains("  \(command) "))
    }
    // Every command works: nothing is listed as planned any more.
    #expect(!result.stdout.contains("Not yet available"))
    #expect(result.stdout.contains("Exit status"))
    #expect(result.stderr.isEmpty)
}

@Test func helpUsesTheInvokedProgramName() {
    let result = prism(["--help"], name: "prism-diff")
    #expect(result.stdout.contains("usage: prism-diff"))
}

@Test(arguments: [["diff"], ["sniff"], ["merge3"], ["help"], ["-h"], ["--help"], ["--version"], [],
                   ["diff", "a", "b"], ["merge3", "--help"]])
func engineArgumentsRunTheEngine(args: [String]) {
    #expect(PrismCommand.isEngineInvocation(args))
    #expect(clientArguments(args) == nil)
}

@Test(arguments: [
    ["a.txt", "b.txt"],
    ["./diff", "./sniff"],
    ["Diff", "x"],
    ["--partial-changeset", "--relative-path", "f", "--", "/tmp/a", "/tmp/b"],
    ["--merge", "--output", "o", "--base", "b", "--", "l", "--snapshot", "r", "--snapshot"],
    ["--wait", "a", "b"], ["-w", "a", "b"], ["--UUID", "x", "a", "b"],
    ["--short-version"], ["--supports-capability", "merges-v1"], ["--bogus"], ["frobnicate"],
    ["-u", "-L", "left", "-L", "right", "a", "b"],
])
func everyOtherFirstArgumentOpensTheApp(args: [String]) {
    #expect(!PrismCommand.isEngineInvocation(args))
    #expect(clientArguments(args) == args)
    #expect(prism(args).status == clientStatus)
}

@Test func aFileNamedDiffIsReachedThroughAPath() {
    #expect(clientArguments(["diff", "other"]) == nil)
    #expect(clientArguments(["./diff", "other"]) == ["./diff", "other"])
}

@Test func helpDescribesBothModes() {
    let text = prism(["help"]).stdout
    #expect(text == prism(["--help"]).stdout)
    #expect(text.contains("--partial-changeset"))
    #expect(text.contains("--merge"))
    #expect(text.contains("./diff"))
    #expect(text.contains("merge3"))
}

@Test func writeFailureStatusFollowsTheMode() {
    #expect(PrismCommand.writeFailureStatus(for: ["diff", "a", "b"]) == 2)
    #expect(PrismCommand.writeFailureStatus(for: ["a", "b"]) == 1)
}

@Test(arguments: [["--version", "extra"], ["help", "x"]])
func otherArgumentsAreUsageErrors(args: [String]) {
    let result = prism(args)
    #expect(result.status == 2)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("usage: prism"))
    #expect(result.stderr.contains("try 'prism --help'"))
}

@Test func sniffWithoutFilesIsAUsageError() {
    let result = prism(["sniff"])
    #expect(result.status == 2)
    #expect(result.stderr.hasPrefix("prism sniff: no file given\n"))
    #expect(result.stderr.contains("usage: prism sniff"))
}

@Test func noArgumentsIsAUsageError() {
    let result = prism([])
    #expect(result.status == 2)
    #expect(result.stdout.isEmpty)
    #expect(!result.stderr.isEmpty)
}

@Test(arguments: [
    ("/usr/local/bin/prism-diff", "prism-diff"),
    ("prism", "prism"),
    ("./build/prism", "prism"),
    ("", "prism"),
])
func programNameIsTheArgv0Basename(argv0: String, expected: String) {
    #expect(PrismCommand.programName(fromArgv0: argv0) == expected)
}

@Test func programNameDefaultsWhenArgv0IsMissing() {
    #expect(PrismCommand.programName(fromArgv0: nil) == "prism")
}
