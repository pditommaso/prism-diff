// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
@testable import PrismProtocol

@Test func ownRecordHasNameParentAndStartTime() throws {
    let record = try #require(ProcessTable.record(of: getpid()))
    #expect(record.pid == getpid())
    #expect(record.parentPID == getppid())
    #expect(!record.name.isEmpty)
    #expect(record.identity.startSeconds > 1_600_000_000)
    #expect(ProcessTable.isRunning(record.identity))
    var recycled = record.identity
    recycled.startMicroseconds = (recycled.startMicroseconds + 1) % 1_000_000
    #expect(!ProcessTable.isRunning(recycled))
}

@Test func missingProcessHasNoRecord() {
    #expect(ProcessTable.record(of: 999_999) == nil)
    #expect(!ProcessTable.isRunning(ProcessIdentity(pid: 999_999, startSeconds: 1, startMicroseconds: 0)))
}

@Test func ownArgumentsCanBeRead() throws {
    let args = try #require(ProcessTable.arguments(of: getpid()))
    #expect(args == CommandLine.arguments)
}

@Test func ancestorsStartWithTheParent() {
    let ancestors = ProcessTable.ancestors()
    #expect(ancestors.first?.pid == getppid())
    #expect(!ancestors.contains { $0.pid <= 1 })
}

@Test func procargsBufferIsParsed() {
    var bytes: [UInt8] = []
    withUnsafeBytes(of: Int32(3)) { bytes += $0 }
    bytes += Array("/usr/bin/git".utf8) + [0, 0, 0, 0]
    for arg in ["git", "diff", "HEAD~1"] { bytes += Array(arg.utf8) + [0] }
    bytes += Array("PATH=/bin".utf8) + [0]
    #expect(ProcessTable.parseProcargs(bytes) == ["git", "diff", "HEAD~1"])
    #expect(ProcessTable.parseProcargs([1, 0]) == nil)
}

@Test(arguments: [
    ("git", nil, VersionControlTool.git),
    ("svn", nil, .subversion),
    ("p4", nil, .perforce),
    ("hg", nil, .mercurial),
    ("Python", ["/usr/bin/python3", "/usr/local/bin/hg", "extdiff"], .mercurial),
    ("python3.12", ["python3.12", "/opt/bin/bzr", "diff"], .bazaar),
] as [(String, [String]?, VersionControlTool)])
func toolsAreRecognised(name: String, arguments: [String]?, tool: VersionControlTool) {
    #expect(CallerDetection.tool(name: name, arguments: arguments) == tool)
}

@Test func otherProcessesAreNotTools() {
    #expect(CallerDetection.tool(name: "sh", arguments: nil) == nil)
    #expect(CallerDetection.tool(name: "Python", arguments: ["python", "script.py"]) == nil)
}

private func record(_ pid: Int32, _ name: String, parent: Int32) -> ProcessRecord {
    ProcessRecord(identity: ProcessIdentity(pid: pid, startSeconds: 100 + Int64(pid), startMicroseconds: 5),
                  parentPID: parent, name: name)
}

@Test func callerIsTheNearestVersionControlAncestor() {
    // prism <- sh <- sh (git-difftool--helper) <- git diff <- git difftool <- bash
    let chain = [record(10, "sh", parent: 11), record(11, "sh", parent: 12),
                 record(12, "git", parent: 13), record(13, "git", parent: 14), record(14, "bash", parent: 1)]
    let caller = CallerDetection.caller(
        ancestors: chain,
        arguments: { $0 == 12 ? ["git", "diff"] : nil },
        workingDirectory: "/w/repo"
    )
    #expect(caller.process?.pid == 12)
    #expect(caller.process?.groupKey == "PID:12-112.5")
    #expect(caller.tool == .git)
    #expect(caller.arguments == ["git", "diff"])
    #expect(caller.workingDirectory == "/w/repo")
}

@Test func callerFallsBackToTheParent() {
    let chain = [record(20, "zsh", parent: 21), record(21, "Terminal", parent: 1)]
    let caller = CallerDetection.caller(ancestors: chain, arguments: { _ in ["-zsh"] }, workingDirectory: "/w")
    #expect(caller.process?.pid == 20)
    #expect(caller.tool == .unknown)
    #expect(caller.arguments == ["-zsh"])
    let orphan = CallerDetection.caller(ancestors: [], arguments: { _ in nil }, workingDirectory: "/w")
    #expect(orphan.process == nil)
}

// MARK: - Temporary files

@Test(arguments: [
    ("/tmp/x/a.txt", true),
    ("/private/tmp/a", true),
    ("/var/folders/ab/T/git-blob-xyz/conf.ini", true),
    ("/private/var/folders/ab/T/a", true),
    ("/Users/me/T/a", true),                       // the caller's TMPDIR
    ("/Users/me/repo/a.txt", false),
    ("/Users/me/repo/.svn/tmp/a.txt", true),
    ("/Users/me/repo/.svn/text-base/a.txt.svn-base", true),
    ("/Volumes/x/Project-Tmp-1/a", true),
    ("/Users/me/repo.1a2b3c4d5e6f/a.txt", true),   // hg extdiff copy
    ("/Users/me/repo.1a2b3c4d5e6f", true),
    ("/Users/me/repo.1A2B3C4D5E6F/a.txt", false),  // hex digits are lowercase
    ("/Users/me/repo.1a2b3c4d5e/a.txt", false),    // 11 digits
    ("/Users/me/.1a2b3c4d5e6f/a", false),          // nothing before the dot
    ("/dev/null", false),
])
func temporaryFileRule(path: String, temporary: Bool) {
    let rule = TemporaryFileRule(environment: ["TMPDIR": "/Users/me/T/"])
    #expect(rule.isTemporary(path) == temporary)
}

@Test func temporaryPrefixesMatchWholeComponents() {
    let rule = TemporaryFileRule(prefixes: ["/tmp/"])
    #expect(!rule.isTemporary("/tmpfiles/a"))
    #expect(rule.isTemporary("/tmp/a"))
}

// MARK: - Titles

private func info(_ tool: VersionControlTool, _ args: [String], cwd: String = "/w/repo") -> CallerInfo {
    CallerInfo(process: nil, name: "", arguments: args, tool: tool, workingDirectory: cwd)
}

@Test(arguments: [
    (info(.git, ["git", "diff"]), "Changes in repo"),
    (info(.git, ["/usr/bin/git", "difftool", "-y"]), "\u{201C}-y\u{201D} in repo"),
    (info(.git, ["git", "diff", "HEAD~1", "--", "src"]), "\u{201C}HEAD~1 -- src\u{201D} in repo"),
    (info(.subversion, ["svn", "diff", "--diff-cmd=prism", "-r", "3"]), "\u{201C}-r 3\u{201D} in repo"),
    (info(.mercurial, ["/usr/bin/python3", "/usr/local/bin/hg", "extdiff"]), "Changes in repo"),
    (info(.unknown, []), "Changes in repo"),
])
func changesetTitles(caller: CallerInfo, title: String) {
    #expect(ChangesetTitle.suggested(for: caller) == title)
}
