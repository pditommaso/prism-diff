// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Testing
import PrismProtocol
import PrismTestSupport
@testable import PrismClient

/// A context that can never reach or start a real app.
func noAppContext() -> ClientContext {
    ClientContext(
        environment: [IPCEnvironment.socketPathVariable: "/nonexistent/prism-test.sock"],
        workingDirectory: "/nonexistent",
        caller: { CallerInfo(process: nil, name: "test", arguments: [], tool: .unknown, workingDirectory: "/nonexistent") },
        launcher: AppLauncher { throw AppLauncher.LaunchError(message: "no app in tests") }
    )
}

private struct Result {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func prism(_ args: String...) -> Result {
    let out = CapturedOutput()
    let err = CapturedOutput()
    let status = ClientCommand.run(args, stdout: out.sink, stderr: err.sink, context: noAppContext())
    return Result(status: status, stdout: out.text, stderr: err.text)
}

@Test func versionPrintsSemverAndNewline() {
    let result = prism("--version")
    #expect(result.status == 0)
    #expect(result.stdout == PrismInfo.version + "\n")
    #expect(PrismInfo.isSemver(String(result.stdout.dropLast())))
    #expect(result.stderr.isEmpty)
}

@Test func shortVersionIncludesBuildNumber() {
    let result = prism("--short-version")
    #expect(result.status == 0)
    #expect(result.stdout == "\(PrismInfo.version) (\(PrismInfo.build))\n")
    #expect(result.stderr.isEmpty)
}

@Test(arguments: ["-h", "--help"])
func helpExitsZeroAndNamesTheCommand(flag: String) {
    let result = prism(flag)
    #expect(result.status == 0)
    #expect(result.stdout.contains("usage: prism"))
    #expect(result.stdout.contains("--partial-changeset"))
    #expect(result.stdout.contains("PRISM_SOCKET_PATH"))
    #expect(result.stderr.isEmpty)
}

@Test(arguments: [["--bogus"], ["--version", "extra"], ["--wait"]])
func otherArgumentsAreUsageErrors(args: [String]) {
    let out = CapturedOutput()
    let err = CapturedOutput()
    let status = ClientCommand.run(args, stdout: out.sink, stderr: err.sink, context: noAppContext())
    #expect(status == 1)
    #expect(out.text.isEmpty)
    #expect(err.text.contains("usage: prism [-w | --wait | --no-wait] FILE ..."))
    #expect(err.text.contains("try 'prism --help'"))
}

@Test func unknownOptionIsNamedInTheError() {
    let result = prism("--bogus")
    #expect(result.stderr.hasPrefix("prism: unrecognised option '--bogus'\n"))
}

@Test func noArgumentsIsAUsageError() {
    let result = prism()
    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("usage: prism"))
}

@Test(arguments: [
    (["--version", "extra"], "prism: '--version' must be used on its own\n"),
    (["a.txt", "--help"], "prism: '--help' must be used on its own\n"),
    (["a.txt", "--bogus"], "prism: unrecognised option '--bogus'\n"),
    (["--wait"], "prism: no files given\n"),
    (["--wait", "/nonexistent/a.txt", "/nonexistent/b.txt"], "prism: /nonexistent/a.txt: no such file or directory\n"),
    (["--", "/nonexistent/--version"], "prism: /nonexistent/--version: no such file or directory\n"),
])
func usageErrorNamesTheActualProblem(args: [String], firstLine: String) {
    let out = CapturedOutput()
    let err = CapturedOutput()
    let status = ClientCommand.run(args, stdout: out.sink, stderr: err.sink, context: noAppContext())
    #expect(status == 1)
    #expect(err.text.hasPrefix(firstLine))
}

@Test(arguments: ["-w", "--wait", "--no-wait"])
func waitOptionsAreKnown(option: String) {
    #expect(ClientCommand.usageLine.contains(option))
    #expect(ClientCommand.helpText.contains(option))
    #expect(throws: Never.self) { try ClientArguments.parse([option, "a.txt", "b.txt"]) }
}

@Test(arguments: [["--short-version", "a.txt"], ["--short-version", "--bogus"], ["--short-version", "--version"]])
func leadingShortVersionIsAnsweredBeforeOtherArguments(args: [String]) {
    let out = CapturedOutput()
    let err = CapturedOutput()
    let status = ClientCommand.run(args, stdout: out.sink, stderr: err.sink, context: noAppContext())
    #expect(status == 0)
    #expect(out.text == "\(PrismInfo.version) (\(PrismInfo.build))\n")
    #expect(err.text.isEmpty)
}

@Test func shortVersionAfterOtherArgumentsIsAUsageError() {
    let result = prism("a.txt", "--short-version")
    #expect(result.status == 1)
    #expect(result.stderr.hasPrefix("prism: '--short-version' must be used on its own\n"))
}

@Test(arguments: [
    (["-w", "--no-wait", "a.txt", "b.txt"], "prism: '-w' and '--no-wait' conflict: use at most one of -w, --wait, --no-wait\n"),
    (["--no-wait", "a.txt", "--wait", "b.txt"], "prism: '--no-wait' and '--wait' conflict: use at most one of -w, --wait, --no-wait\n"),
    (["-w", "--wait", "a.txt"], "prism: '-w' and '--wait' conflict: use at most one of -w, --wait, --no-wait\n"),
    (["-w", "-w", "a.txt"], "prism: '-w' given more than once: use at most one of -w, --wait, --no-wait\n"),
])
func waitOptionsAreMutuallyExclusive(args: [String], firstLine: String) {
    let out = CapturedOutput()
    let err = CapturedOutput()
    let status = ClientCommand.run(args, stdout: out.sink, stderr: err.sink, context: noAppContext())
    #expect(status == 1)
    #expect(out.text.isEmpty)
    #expect(err.text.hasPrefix(firstLine))
}
