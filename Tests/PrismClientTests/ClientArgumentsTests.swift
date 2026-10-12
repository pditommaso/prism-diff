// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Testing
import PrismProtocol
@testable import PrismClient

private func parseOpen(_ args: [String]) throws -> OpenArguments {
    guard case .open(let open) = try ClientArguments.parse(args) else {
        throw UsageError("not an open request")
    }
    return open
}

private func file(_ path: String, _ snapshot: Bool? = nil) -> ParsedFile {
    ParsedFile(path: path, snapshot: snapshot)
}

private func errorMessage(_ args: [String]) -> String? {
    do {
        _ = try ClientArguments.parse(args)
        return nil
    } catch {
        return error.message
    }
}

@Test func plainFilesAreADiffThatDoesNotWait() throws {
    let open = try parseOpen(["a", "b"])
    #expect(open.kind == .diff)
    #expect(!open.waits)
    #expect(open.fileLists == [ParsedFileList(files: [file("a"), file("b")])])
    #expect(try parseOpen(["--diff", "a", "b", "c"]).fileLists[0].files.count == 3)
}

@Test(arguments: [(["-w"], true), (["--wait"], true), (["--no-wait"], false)])
func waitOptions(option: [String], waits: Bool) throws {
    #expect(try parseOpen(option + ["a", "b"]).waits == waits)
    #expect(try parseOpen(option + ["--partial-changeset", "a", "b"]).waits == waits)
    #expect(try parseOpen(["--changeset"] + option + ["--filelist", "a", "b"]).waits == waits)
}

@Test func gitDifftoolCommandLine() throws {
    // difftool.prism.cmd = prism --partial-changeset --relative-path "$MERGED" -- "$LOCAL" "$REMOTE"
    let open = try parseOpen(["--partial-changeset", "--relative-path", "src/a.c", "--", "/tmp/x/a.c", "src/a.c"])
    #expect(open.kind == .partialChangeset)
    #expect(open.fileLists == [ParsedFileList(files: [file("/tmp/x/a.c"), file("src/a.c")], relativePath: "src/a.c")])
    #expect(!open.waits)
}

@Test func snapshotFlagsAfterDoubleDashStillApply() throws {
    // The spec correction: per-file flags are honoured after `--`.
    let open = try parseOpen(["--partial-changeset", "--", "L", "--snapshot", "R", "--no-snapshot"])
    #expect(open.fileLists[0].files == [file("L", true), file("R", false)])
}

@Test func otherOptionsAfterDoubleDashAreFiles() throws {
    let open = try parseOpen(["--", "--wait", "--label", "-x"])
    #expect(open.fileLists[0].files == [file("--wait"), file("--label"), file("-x")])
    #expect(open.wait == nil)
    #expect(open.label == nil)
}

@Test func equalsFormIsSplitOnlyBeforeDoubleDash() throws {
    let open = try parseOpen(["--label=My title", "--partial-changeset", "--relative-path=x=y", "--", "--a=b", "c"])
    #expect(open.label == "My title")
    #expect(open.fileLists[0].relativePath == "x=y")
    #expect(open.fileLists[0].files == [file("--a=b"), file("c")])
    #expect(ClientArguments.tokenize(["--file-status=added", "--", "--x=y"]) == ["--file-status", "added", "--", "--x=y"])
}

@Test func changesetFileLists() throws {
    let open = try parseOpen([
        "--changeset", "--wait",
        "--filelist", "--relative-path", "a.txt", "l/a.txt", "r/a.txt",
        "--filelist", "--file-status", "added", "/dev/null", "r/b.txt",
        "--filelist", "l/c.txt", "--snapshot", "/dev/null",
    ])
    #expect(open.kind == .changeset)
    #expect(open.waits)
    #expect(open.fileLists == [
        ParsedFileList(files: [file("l/a.txt"), file("r/a.txt")], relativePath: "a.txt"),
        ParsedFileList(files: [file("/dev/null"), file("r/b.txt")], status: .added),
        ParsedFileList(files: [file("l/c.txt", true), file("/dev/null")]),
    ])
}

@Test func changesetWithoutFilelistUsesOneList() throws {
    let open = try parseOpen(["--changeset", "l", "r"])
    #expect(open.fileLists == [ParsedFileList(files: [file("l"), file("r")])])
}

@Test func uuidAndLabel() throws {
    let open = try parseOpen(["--partial-changeset", "--UUID", "abc", "--label", "T", "a", "b"])
    #expect(open.changesetUUID == "abc")
    #expect(open.label == "T")
}

@Test func informationalCommands() throws {
    #expect(try ClientArguments.parse(["--version"]) == .version)
    #expect(try ClientArguments.parse(["--short-version", "anything"]) == .shortVersion)
    #expect(try ClientArguments.parse(["-h"]) == .help)
    #expect(try ClientArguments.parse(["--supports-capability", "changesets-v1"]) == .supportsCapability("changesets-v1"))
    #expect(try ClientArguments.parse(["--mark-changeset-as-closed", "U"]) == .markChangesetClosed("U"))
    #expect(try ClientArguments.parse(["--mark-changeset-as-closed=U"]) == .markChangesetClosed("U"))
}

@Test(arguments: [
    (["--merge", "a", "b"], "a merge needs an --output path for the result"),
    (["--merge", "--no-wait", "--output", "o", "a", "b"],
     "'--no-wait' cannot be used with --merge, which waits for the result"),
    (["--merge", "--output", "o", "a"], "--merge needs exactly two files, got 1"),
    (["--merge", "--output", "o", "a", "b", "c"], "--merge needs exactly two files, got 3"),
    (["--output", "o", "a", "b"], "'--output' needs --merge"),
    (["--base", "o", "a", "b"], "'--base' needs --merge"),
    (["--merge", "--changeset", "a", "b"], "use at most one of --diff, --partial-changeset, --changeset, --merge"),
    (["--merge", "--output", "o", "--output", "p", "a", "b"], "'--output' given twice"),
    (["--merge", "--output", "o", "--base", "x", "--snapshot", "--no-snapshot", "a", "b"],
     "use at most one of --snapshot, --no-snapshot per file"),
    (["--label"], "'--label' needs a value"),
    (["--partial-changeset", "a"], "--partial-changeset needs exactly two files, got 1"),
    (["--partial-changeset", "a", "b", "c"], "--partial-changeset needs exactly two files, got 3"),
    (["--changeset", "--filelist", "a", "--filelist", "b", "c"], "each --filelist needs exactly two files, got 1"),
    (["--diff", "--changeset", "a", "b"], "use at most one of --diff, --partial-changeset, --changeset, --merge"),
    (["--UUID", "u", "a", "b"], "'--UUID' needs --partial-changeset"),
    (["--relative-path", "p", "a", "b"], "'--relative-path' needs --partial-changeset or --changeset"),
    (["--file-status", "added", "a", "b"], "'--file-status' needs --partial-changeset or --changeset"),
    (["--partial-changeset", "--file-status", "gone", "a", "b"], "'--file-status' must be added, removed or changed, not 'gone'"),
    (["--snapshot", "a", "b"], "'--snapshot' must follow a file"),
    (["a", "--snapshot", "--no-snapshot", "b"], "use at most one of --snapshot, --no-snapshot per file"),
    (["--partial-changeset", "a", "a"], "the same file appears twice in one comparison"),
    (["--filelist", "a", "b", "--filelist", "c", "d"], "'--filelist' needs --changeset"),
    (["--mark-changeset-as-closed", "U", "a"], "'--mark-changeset-as-closed' must be used on its own"),
    (["--supports-capability", "x", "a"], "'--supports-capability' must be used on its own"),
    ([], "no files given"),
    (["--label", "x"], "no files given"),
])
func grammarErrors(args: [String], message: String) {
    #expect(errorMessage(args) == message)
}

@Test func placeholdersMayRepeat() throws {
    _ = try parseOpen(["--partial-changeset", "/dev/null", "/dev/null"])
}

@Test func capabilitiesIncludeMerging() {
    #expect(ClientArguments.capabilities.contains("partial-changesets-v1"))
    #expect(ClientArguments.capabilities.contains("merges-v1"))
}

@Test func gitMergetoolCommandLine() throws {
    // The command Prism's git integration installs.
    let open = try parseOpen(["--merge", "--output", "notes.txt", "--base", "notes_BASE_1.txt", "--",
                              "notes_LOCAL_1.txt", "--snapshot", "notes_REMOTE_1.txt", "--snapshot"])
    #expect(open.kind == .merge)
    #expect(open.waits, "a merge waits by default")
    #expect(open.output == "notes.txt")
    #expect(open.base == file("notes_BASE_1.txt"))
    #expect(open.fileLists == [ParsedFileList(files: [file("notes_LOCAL_1.txt", true), file("notes_REMOTE_1.txt", true)])])
}

@Test func mergeOptionsInEveryForm() throws {
    let open = try parseOpen(["--merge", "--output=out", "--base=base", "--no-snapshot", "a", "b"])
    #expect(open.output == "out" && open.base == file("base", false))
    #expect(open.waits)
    #expect(try parseOpen(["-w", "--merge", "--output", "o", "a", "b"]).waits)
    #expect(try parseOpen(["--merge", "--output", "o", "a", "b"]).base == nil)
}

// MARK: - Native dialects

@Test func subversionDiffArguments() throws {
    let native = ["-u", "-L", "src/a.c\t(revision 3)", "-L", "src/a.c\t(working copy)",
                  "/repo/.svn/pristine/ab/abc.svn-base", "/repo/src/a.c"]
    let rewritten = try #require(NativeDialect.rewrite(native, tool: .subversion))
    #expect(rewritten == ["--partial-changeset", "--relative-path", "src/a.c", "--",
                          "/repo/.svn/pristine/ab/abc.svn-base", "/repo/src/a.c"])
    #expect(NativeDialect.rewrite(native, tool: .git) == nil)
    #expect(NativeDialect.rewrite(["a", "b"], tool: .subversion) == nil)
}

@Test func perforceDiffArguments() {
    #expect(NativeDialect.rewrite(["/tmp/p4a", "/ws/a.c"], tool: .perforce)
            == ["--partial-changeset", "--", "/tmp/p4a", "/ws/a.c"])
    #expect(NativeDialect.rewrite(["-w", "a"], tool: .perforce) == nil)
    #expect(NativeDialect.rewrite(["a", "b", "c"], tool: .perforce) == nil)
}
