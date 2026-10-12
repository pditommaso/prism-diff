// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismProtocol
import PrismTestSupport
@testable import PrismClient

private struct Workspace {
    let directory: TemporaryDirectory
    var root: String { directory.url.path }

    init() throws {
        directory = try TemporaryDirectory(prefix: "prism-resolve")
    }

    func write(_ relative: String, _ text: String = "x\n") throws {
        let url = directory.url.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A resolver for this workspace in which only `scratch/` is temporary.
    var resolver: ClientResolver {
        ClientResolver(workingDirectory: root, temporaryRule: TemporaryFileRule(prefixes: [root + "/scratch/"]))
    }

    func lists(_ args: [String]) throws -> [FileList] {
        guard case .open(let open) = try ClientArguments.parse(args) else { throw UsageError("not open") }
        return try resolver.fileLists(for: open)
    }
}

@Test func diffPathsBecomeAbsolute() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("a.txt")
    try space.write("sub/b.txt")
    let lists = try space.lists(["a.txt", "sub/../sub/b.txt"])
    #expect(lists == [FileList(files: [
        FileReference(path: space.root + "/a.txt", temporary: false),
        FileReference(path: space.root + "/sub/b.txt", temporary: false),
    ])])
}

@Test func diffRequiresExistingFiles() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("a.txt")
    #expect(throws: UsageError("missing.txt: no such file or directory")) { try space.lists(["a.txt", "missing.txt"]) }
}

@Test func partialChangesetMarksAddedAndRemovedSides() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("new.txt")
    let added = try space.lists(["--partial-changeset", "/dev/null", "new.txt"])
    #expect(added[0].status == .added)
    #expect(added[0].relativePath == "new.txt")
    #expect(added[0].files[0].isPlaceholder)
    // A missing file in a changeset is a placeholder, not an error.
    let removed = try space.lists(["--partial-changeset", "new.txt", "gone.txt"])
    #expect(removed[0].status == .removed)
    #expect(removed[0].files[1] == FileReference(path: "/dev/null", temporary: false))
    let forced = try space.lists(["--partial-changeset", "--file-status", "changed", "/dev/null", "new.txt"])
    #expect(forced[0].status == .changed)
}

@Test func temporaryRuleAndSnapshotFlags() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("scratch/blob.txt")
    try space.write("work.txt")
    let byRule = try space.lists(["--partial-changeset", "--", "scratch/blob.txt", "work.txt"])
    #expect(byRule[0].files.map(\.temporary) == [true, false])
    let forced = try space.lists(["--partial-changeset", "--", "scratch/blob.txt", "--no-snapshot", "work.txt", "--snapshot"])
    #expect(forced[0].files.map(\.temporary) == [false, true])
}

@Test func defaultRelativePath() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("src/x.c")
    let inside = try space.lists(["--partial-changeset", "/dev/null", "src/x.c"])
    #expect(inside[0].relativePath == "src/x.c")
    let elsewhere = ClientResolver(workingDirectory: "/somewhere/else", temporaryRule: TemporaryFileRule(prefixes: []))
    #expect(elsewhere.defaultRelativePath([FileReference(path: space.root + "/src/x.c", temporary: false)]) == "x.c")
}

@Test func folderPairsExpandToEveryFile() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("left/same.txt")
    try space.write("left/only-left.txt")
    try space.write("left/sub/deep.txt")
    try space.write("right/same.txt")
    try space.write("right/only-right.txt")
    try space.write("right/sub/deep.txt")
    let lists = try space.lists(["--changeset", "--filelist", "left", "right"])
    #expect(lists.map(\.relativePath) == ["only-left.txt", "only-right.txt", "same.txt", "sub/deep.txt"])
    #expect(lists.map(\.status) == [.removed, .added, .changed, .changed])
    #expect(lists[2].files.map(\.path) == [space.root + "/left/same.txt", space.root + "/right/same.txt"])
    let prefixed = try space.lists(["--changeset", "--filelist", "--relative-path", "pkg", "left", "right"])
    #expect(prefixed.first?.relativePath == "pkg/only-left.txt")
}

@Test func folderAgainstFileIsAnError() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("dir/a.txt")
    try space.write("file.txt")
    #expect(throws: UsageError("cannot compare a folder with a file in one --filelist")) {
        try space.lists(["--changeset", "--filelist", "dir", "file.txt"])
    }
}

@Test func invocationCarriesCallerAndOptions() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("a")
    try space.write("b")
    guard case .open(let open) = try ClientArguments.parse(["-w", "--label", "L", "a", "b"]) else { return }
    let caller = CallerInfo(process: nil, name: "zsh", arguments: [], tool: .unknown, workingDirectory: space.root)
    let invocation = try space.resolver.invocation(for: open, caller: caller)
    #expect(invocation.kind == .diff)
    #expect(invocation.wait)
    #expect(invocation.label == "L")
    #expect(invocation.caller == caller)
    #expect(invocation.clientPID == getpid())
}

@Test func foldersAreNeverMarkedTemporary() throws {
    let space = try Workspace()
    defer { space.directory.remove() }
    try space.write("scratch/dir/a.txt")
    try space.write("scratch/b.txt")
    let lists = try space.lists(["--", "scratch/dir", "--snapshot", "scratch/b.txt"])
    #expect(lists[0].files.map(\.temporary) == [false, true])
}
