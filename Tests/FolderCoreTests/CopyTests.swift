// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation
import PrismTestSupport
import Testing
@testable import FolderCore

// Every test works in its own temporary directory. Replaced items go to a
// `DirectoryTrash` inside that directory, never to the user's Trash; the
// only test of the Finder Trash runs when PRISM_TEST_REAL_TRASH=1 and
// removes the one item it trashed.

private func contents(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func mtime(_ path: String) -> timespec {
    var info = stat()
    _ = lstat(path, &info)
    return info.st_mtimespec
}

/// Names in a directory that start with the copier's temporary prefix,
/// searched recursively.
private func leftovers(_ root: String) -> [String] {
    (FileManager.default.subpaths(atPath: root) ?? []).filter {
        ($0 as NSString).lastPathComponent.hasPrefix(".prism-copy-")
    }
}

/// A staged copy for a path, built from the current rows of its level.
private func staged(_ left: String, _ right: String, _ relativePath: String, _ direction: CopyDirection) throws -> StagedCopy {
    let level = (relativePath as NSString).deletingLastPathComponent
    let name = (relativePath as NSString).lastPathComponent
    let rows = FolderSession.compare(left: left, right: right, relativePath: level).rows
    let row = try #require(rows.first { $0.name == name })
    var staging = FolderStaging(levelPath: level)
    staging.set(row, direction)
    return try #require(staging.ordered.first)
}

/// Makes a path writable again so the temporary directory can be removed.
private func unlock(_ path: String) { _ = chmod(path, 0o755) }

@Suite struct StagingTests {
    private func row(_ name: String, _ status: RowStatus, left: Bool = true, right: Bool = true,
                     directory: Bool = false) -> FolderRow {
        func entry() -> FolderEntry {
            FolderEntry(name: name, kind: directory ? .directory : .file, size: 10, modificationTimeNs: 0,
                        isReadable: true, key: UInt64(name.hashValue.magnitude), isDeep: true)
        }
        return FolderRow(left: left ? entry() : nil, right: right ? entry() : nil, status: status)
    }

    @Test func directionsFollowTheRowStatus() {
        #expect(row("a", .leftOnly, right: false).allowedDirections == [.toRight])
        #expect(row("a", .rightOnly, left: false).allowedDirections == [.toLeft])
        #expect(row("a", .changed).allowedDirections == [.toRight, .toLeft])
        #expect(row("a", .unchanged).allowedDirections.isEmpty)
    }

    @Test func stagingAppliesOnlyWhereAllowedAndCycles() {
        var staging = FolderStaging(levelPath: "src")
        let only = row("docs", .leftOnly, right: false, directory: true)
        let changed = row("main.swift", .changed)
        let same = row("README.md", .unchanged)
        let right = row("assets", .rightOnly, left: false)
        let staged1 = staging.stage([only, changed, same, right], .toRight)
        #expect(staged1)
        #expect(staging.count == 2)
        #expect(staging.direction(of: right) == nil && staging.direction(of: same) == nil)
        let docs = staging.ordered.first { $0.name == "docs" }
        #expect(docs?.relativePath == "src/docs" && docs?.replaces == false && docs?.isDirectory == true)
        #expect(staging.ordered.first { $0.name == "main.swift" }?.replaces == true)
        let staged2 = staging.stage([only], .toRight)
        #expect(!staged2, "staging the same choice again changes nothing")

        // The gutter button: right, left, none for a changed row.
        staging.cycle(changed)
        #expect(staging.direction(of: changed) == .toLeft)
        staging.cycle(changed)
        #expect(staging.direction(of: changed) == nil)
        staging.cycle(changed)
        #expect(staging.direction(of: changed) == .toRight)
        staging.cycle(same)
        #expect(staging.direction(of: same) == nil)

        // Snapshots compare by value (what undo relies on).
        let snapshot = staging
        let reset = staging.reset([changed])
        #expect(reset)
        #expect(staging != snapshot && staging.count == 1)
        staging = snapshot
        #expect(staging.count == 2)
        staging.resetAll()
        #expect(staging.isEmpty)
    }

    @Test func orderIsByNameAndReconcileDropsStaleChoices() {
        var staging = FolderStaging(levelPath: "")
        let rows = [row("b10", .leftOnly, right: false), row("B2", .leftOnly, right: false), row("a", .changed)]
        staging.stage(rows, .toRight)
        #expect(staging.ordered.map(\.name) == ["a", "B2", "b10"])
        #expect(staging.totalBytes == 30)
        // After the copy "a" is unchanged and "B2" exists on both sides as
        // a changed pair: "a" goes, "B2" now replaces, "b10" vanished.
        let fresh = [row("a", .unchanged), row("B2", .changed)]
        let reconciled = staging.reconcile(with: fresh)
        #expect(reconciled)
        #expect(staging.count == 0, "B2 changed identity (now on both sides), so its choice is dropped")
        staging.stage([row("B2", .changed)], .toRight)
        let again = staging.reconcile(with: [row("B2", .changed)])
        #expect(!again)
        #expect(staging.count == 1)
    }
}

@Suite(.serialized) struct CopyTests {
    // MARK: the acceptance cases

    @Test func copyingAFolderToTheRightMakesItsRowEqual() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let before = FolderSession.compare(left: fixture.left, right: fixture.right)
        #expect(before.counts == FolderCounts(changed: 1, unchanged: 1, unmatched: 4))
        let trash = DirectoryTrash(directory: fixture.directory.url.appending(path: "trash").path(percentEncoded: false))
        let copier = FolderCopier(leftRoot: fixture.left, rightRoot: fixture.right,
                                  items: [try staged(fixture.left, fixture.right, "docs", .toRight)], trash: trash)
        var last: CopyProgress?
        let outcome = copier.run(progress: { last = $0 })
        #expect(outcome.copied == ["docs"] && outcome.finished && outcome.trashed.isEmpty)
        #expect(contents(fixture.right + "/docs/guide.md") == contents(fixture.left + "/docs/guide.md"))
        #expect(last?.completedBytes == last?.totalBytes && last?.totalBytes == 10)
        let after = FolderSession.compare(left: fixture.left, right: fixture.right)
        #expect(after.row("docs")?.status == .unchanged)
        #expect(after.counts == FolderCounts(changed: 1, unchanged: 2, unmatched: 3))
        #expect(leftovers(fixture.right).isEmpty)
    }

    @Test func replacingAFileMovesTheOldOneToTheTrash() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let trashDir = fixture.directory.url.appending(path: "trash").path(percentEncoded: false)
        let oldLeft = try #require(contents(fixture.left + "/src/util/helper.swift"))
        let item = try staged(fixture.left, fixture.right, "src/util/helper.swift", .toLeft)
        #expect(item.replaces)
        let outcome = FolderCopier(leftRoot: fixture.left, rightRoot: fixture.right, items: [item],
                                   trash: DirectoryTrash(directory: trashDir), allowClone: false).run()
        #expect(outcome.copied == ["src/util/helper.swift"])
        let trashed = try #require(outcome.trashed["src/util/helper.swift"])
        #expect(trashed == trashDir + "/helper.swift")
        #expect(contents(trashed) == oldLeft)
        #expect(contents(fixture.left + "/src/util/helper.swift") == contents(fixture.right + "/src/util/helper.swift"))
        let level = FolderSession.compare(left: fixture.left, right: fixture.right, relativePath: "src/util")
        #expect(level.row("helper.swift")?.status == .unchanged)
    }

    @Test func cancellingABigCopyLeavesNothingBehind() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-cancel")
        defer { directory.remove() }
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        // 64 MiB, copied in 1 MiB chunks, cancelled after 16 MiB.
        let big = left.url("big.bin").path(percentEncoded: false)
        #expect(FileManager.default.createFile(atPath: big, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(filePath: big))
        for index in 0..<64 { try handle.write(contentsOf: Data(repeating: UInt8(index), count: 1 << 20)) }
        try handle.close()
        try left.setTime("big.bin", TreeBuilder.baseTime)
        try right.file("big.bin", "old", mtime: TreeBuilder.baseTime - 10)
        let oldTime = mtime(big)
        let copier = FolderCopier(leftRoot: left.path, rightRoot: right.path,
                                  items: [try staged(left.path, right.path, "big.bin", .toRight)],
                                  trash: DirectoryTrash(directory: directory.url.appending(path: "trash").path(percentEncoded: false)),
                                  allowClone: false)
        var seen: UInt64 = 0
        let outcome = copier.run(progress: { progress in
            seen = max(seen, progress.completedBytes)
            if progress.completedBytes >= 16 << 20 { copier.cancel() }
        })
        #expect(outcome.cancelled && outcome.copied.isEmpty && outcome.notAttempted == ["big.bin"])
        #expect(seen >= 16 << 20 && seen < 64 << 20)
        #expect(leftovers(right.path).isEmpty, "no partial copy remains")
        #expect(contents(right.path + "/big.bin") == Data("old".utf8), "the destination is untouched")
        #expect(!exists(directory.url.appending(path: "trash").path(percentEncoded: false)))
        var info = stat()
        #expect(lstat(big, &info) == 0 && info.st_size == 64 << 20)
        #expect(mtime(big).tv_sec == oldTime.tv_sec && mtime(big).tv_nsec == oldTime.tv_nsec)
    }

    @Test func readOnlyDestinationAsksAndSkipContinues() throws {
        let fixture = try FolderFixture()
        defer {
            unlock(fixture.right + "/src/util")
            fixture.remove()
        }
        let items = [try staged(fixture.left, fixture.right, "LICENSE", .toRight),
                     try staged(fixture.left, fixture.right, "src/util/helper.swift", .toRight)]
        #expect(chmod(fixture.right + "/src/util", 0o555) == 0)
        let oldRight = contents(fixture.right + "/src/util/helper.swift")
        var failures: [CopyFailure] = []
        let copier = FolderCopier(leftRoot: fixture.left, rightRoot: fixture.right, items: items,
                                  trash: DirectoryTrash(directory: fixture.directory.url.appending(path: "trash").path(percentEncoded: false)))
        // Items run by name: helper.swift, then LICENSE.
        #expect(copier.items.map(\.name) == ["helper.swift", "LICENSE"])
        let outcome = copier.run(onError: { failure in
            failures.append(failure)
            return failures.count == 1 ? .retry : .skip
        })
        #expect(failures.count == 2, "asked once, retried, asked again")
        let failure = try #require(failures.first)
        #expect(failure.relativePath == "src/util/helper.swift" && failure.code == EACCES)
        #expect(failure.title.contains("helper.swift") && failure.reason.contains("Permission denied"))
        #expect(outcome.skipped == ["src/util/helper.swift"] && outcome.copied == ["LICENSE"] && outcome.finished)
        #expect(contents(fixture.right + "/src/util/helper.swift") == oldRight)
        #expect(contents(fixture.right + "/LICENSE") == contents(fixture.left + "/LICENSE"))
    }

    // MARK: errors

    @Test func stopEndsTheCopyAndReportsTheRest() throws {
        let fixture = try FolderFixture()
        defer {
            unlock(fixture.right + "/src/util")
            fixture.remove()
        }
        let items = [try staged(fixture.left, fixture.right, "LICENSE", .toRight),
                     try staged(fixture.left, fixture.right, "src/util/helper.swift", .toRight)]
        #expect(chmod(fixture.right + "/src/util", 0o555) == 0)
        let outcome = FolderCopier(leftRoot: fixture.left, rightRoot: fixture.right, items: items,
                                   trash: DirectoryTrash(directory: fixture.directory.url.appending(path: "trash").path(percentEncoded: false)))
            .run(onError: { _ in .stop })
        #expect(outcome.stopped && outcome.copied.isEmpty && outcome.notAttempted == ["LICENSE"])
        #expect(!exists(fixture.right + "/LICENSE"))
    }

    @Test func anUnreadableFileInsideAFolderFailsTheWholeItemCleanly() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-partial")
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        defer {
            unlock(left.url("pkg/b-secret").path(percentEncoded: false))
            directory.remove()
        }
        try left.file("pkg/a.txt", "a")
        try left.file("pkg/b-secret", "s")
        try left.file("pkg/c.txt", "c")
        try right.file("pkg/old.txt", "old")
        try right.file("zz.txt", "z", mtime: TreeBuilder.baseTime - 5)
        try left.file("zz.txt", "zz")
        #expect(chmod(left.url("pkg/b-secret").path(percentEncoded: false), 0o000) == 0)
        let trashDir = directory.url.appending(path: "trash").path(percentEncoded: false)
        let items = [try staged(left.path, right.path, "pkg", .toRight), try staged(left.path, right.path, "zz.txt", .toRight)]
        var failures: [CopyFailure] = []
        let outcome = FolderCopier(leftRoot: left.path, rightRoot: right.path, items: items,
                                   trash: DirectoryTrash(directory: trashDir), allowClone: false)
            .run(onError: { failures.append($0); return .skip })
        #expect(failures.map(\.relativePath) == ["pkg"])
        #expect(failures.first?.failingPath.hasSuffix("b-secret") == true)
        #expect(outcome.skipped == ["pkg"] && outcome.copied == ["zz.txt"])
        // The old destination folder was neither replaced nor trashed.
        #expect(contents(right.path + "/pkg/old.txt") == Data("old".utf8))
        #expect(!exists(right.path + "/pkg/a.txt"))
        #expect(leftovers(right.path).isEmpty)
        #expect(outcome.trashed.keys.sorted() == ["zz.txt"])
    }

    @Test func missingSourceIsReported() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let item = try staged(fixture.left, fixture.right, "LICENSE", .toRight)
        try FileManager.default.removeItem(atPath: fixture.left + "/LICENSE")
        var codes: [Int32] = []
        let outcome = FolderCopier(leftRoot: fixture.left, rightRoot: fixture.right, items: [item],
                                   trash: DirectoryTrash(directory: fixture.directory.url.appending(path: "trash").path(percentEncoded: false)))
            .run(onError: { codes.append($0.code); return .skip })
        #expect(codes == [ENOENT] && outcome.skipped == ["LICENSE"])
    }

    // MARK: symbolic links

    @Test func symbolicLinksAreCopiedAsLinksNeverFollowed() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-links")
        defer { directory.remove() }
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        let outside = try TreeBuilder(directory.url.appending(path: "outside"))
        try outside.file("big/secret.txt", "outside data")
        try left.symlink("link-out", to: outside.url("big").path(percentEncoded: false))
        try left.file("tree/inner.txt", "i")
        try left.symlink("tree/escape", to: outside.url("big").path(percentEncoded: false))
        try left.symlink("tree/dangling", to: "does-not-exist")
        try right.directory("placeholder")
        let items = [try staged(left.path, right.path, "link-out", .toRight), try staged(left.path, right.path, "tree", .toRight)]
        let outcome = FolderCopier(leftRoot: left.path, rightRoot: right.path, items: items,
                                   trash: DirectoryTrash(directory: directory.url.appending(path: "trash").path(percentEncoded: false)))
            .run(onError: { Issue.record("unexpected failure \($0)"); return .stop })
        #expect(outcome.copied == ["link-out", "tree"])
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: right.path + "/link-out") == outside.url("big").path(percentEncoded: false))
        #expect(try fm.destinationOfSymbolicLink(atPath: right.path + "/tree/escape") == outside.url("big").path(percentEncoded: false))
        #expect(try fm.destinationOfSymbolicLink(atPath: right.path + "/tree/dangling") == "does-not-exist")
        var info = stat()
        #expect(lstat(right.path + "/link-out", &info) == 0 && info.st_mode & S_IFMT == S_IFLNK)
        #expect(fm.subpaths(atPath: outside.path)?.sorted() == ["big", "big/secret.txt"])
        let after = FolderSession.compare(left: left.path, right: right.path)
        #expect(after.row("tree")?.status == .unchanged && after.row("link-out")?.status == .unchanged)
    }

    @Test func aDestinationFolderThatIsALinkOutOfTheRootIsRefused() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-escape")
        defer { directory.remove() }
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        let outside = try TreeBuilder(directory.url.appending(path: "outside"))
        try left.file("src/util/helper.swift", "new")
        try outside.file("util/helper.swift", "outside")
        try right.symlink("src", to: outside.path)
        // Staged while right/src was a real folder; it is a link now.
        let item = StagedCopy(row: FolderRow(left: FolderEntry(name: "helper.swift", kind: .file, size: 3, modificationTimeNs: 0,
                                                               isReadable: true, key: 1, isDeep: true),
                                             right: nil, status: .leftOnly),
                              levelPath: "src/util", direction: .toRight)
        var failures: [CopyFailure] = []
        let outcome = FolderCopier(leftRoot: left.path, rightRoot: right.path, items: [item],
                                   trash: DirectoryTrash(directory: directory.url.appending(path: "trash").path(percentEncoded: false)))
            .run(onError: { failures.append($0); return .skip })
        #expect(outcome.skipped == ["src/util/helper.swift"])
        #expect(failures.first?.code == 0 && failures.first?.reason.contains("symbolic link") == true)
        #expect(contents(outside.path + "/util/helper.swift") == Data("outside".utf8))
        #expect(leftovers(outside.path).isEmpty)
    }

    @Test func aDestinationLinkIsTrashedItselfNotItsTarget() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-link-dest")
        defer { directory.remove() }
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        let outside = try TreeBuilder(directory.url.appending(path: "outside"))
        try outside.file("data/keep.txt", "keep")
        try left.file("data", "now a file")
        try right.symlink("data", to: outside.url("data").path(percentEncoded: false))
        let trashDir = directory.url.appending(path: "trash").path(percentEncoded: false)
        let outcome = FolderCopier(leftRoot: left.path, rightRoot: right.path,
                                   items: [try staged(left.path, right.path, "data", .toRight)],
                                   trash: DirectoryTrash(directory: trashDir)).run()
        #expect(outcome.copied == ["data"])
        #expect(contents(right.path + "/data") == Data("now a file".utf8))
        var info = stat()
        #expect(lstat(trashDir + "/data", &info) == 0 && info.st_mode & S_IFMT == S_IFLNK)
        #expect(contents(outside.path + "/data/keep.txt") == Data("keep".utf8))
    }

    // MARK: kinds, metadata, places

    @Test func aFileReplacesAFolderOfTheSameNameAndBack() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-kinds")
        defer { directory.remove() }
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        try left.file("thing", "a file")
        try right.file("thing/inside.txt", "in a folder")
        try left.directory("other")
        try left.file("other/x.txt", "x")
        try right.file("other", "file on the right")
        let rows = FolderSession.compare(left: left.path, right: right.path).rows
        #expect(rows.first { $0.name == "thing" }?.status == .changed)
        let trashDir = directory.url.appending(path: "trash").path(percentEncoded: false)
        let outcome = FolderCopier(leftRoot: left.path, rightRoot: right.path,
                                   items: [try staged(left.path, right.path, "thing", .toRight),
                                           try staged(left.path, right.path, "other", .toLeft)],
                                   trash: DirectoryTrash(directory: trashDir)).run()
        #expect(outcome.copied == ["other", "thing"])
        #expect(contents(right.path + "/thing") == Data("a file".utf8))
        #expect(contents(trashDir + "/thing/inside.txt") == Data("in a folder".utf8))
        #expect(contents(left.path + "/other") == Data("file on the right".utf8))
        #expect(contents(trashDir + "/other/x.txt") == Data("x".utf8))
        let after = FolderSession.compare(left: left.path, right: right.path)
        #expect(after.counts == FolderCounts(changed: 0, unchanged: 2, unmatched: 0))
    }

    @Test func byteCopyKeepsNanosecondTimesModesAndReadOnlyFolders() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-meta")
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        defer {
            unlock(left.url("locked").path(percentEncoded: false))
            unlock(right.url("locked").path(percentEncoded: false))
            directory.remove()
        }
        try left.file("locked/a.txt", "a")
        try left.file("tool.sh", "#!/bin/sh\n")
        try left.setTime("tool.sh", TreeBuilder.baseTime, nanoseconds: 123_456_789)
        #expect(chmod(left.url("tool.sh").path(percentEncoded: false), 0o751) == 0)
        #expect(chmod(left.url("locked").path(percentEncoded: false), 0o555) == 0)
        try right.directory("x")
        for clone in [false, true] {
            if clone {
                unlock(right.url("locked").path(percentEncoded: false))
                try FileManager.default.removeItem(at: right.url("locked"))
                try FileManager.default.removeItem(at: right.url("tool.sh"))
            }
            let outcome = FolderCopier(leftRoot: left.path, rightRoot: right.path,
                                       items: [try staged(left.path, right.path, "locked", .toRight),
                                               try staged(left.path, right.path, "tool.sh", .toRight)],
                                       trash: DirectoryTrash(directory: directory.url.appending(path: "trash").path(percentEncoded: false)),
                                       allowClone: clone).run()
            #expect(outcome.copied.count == 2)
            let copied = mtime(right.path + "/tool.sh")
            #expect(copied.tv_sec == Int(TreeBuilder.baseTime) && copied.tv_nsec == 123_456_789)
            var info = stat()
            _ = lstat(right.path + "/tool.sh", &info)
            #expect(info.st_mode & 0o777 == 0o751)
            _ = lstat(right.path + "/locked", &info)
            #expect(info.st_mode & 0o777 == 0o555)
            let level = FolderSession.compare(left: left.path, right: right.path)
            #expect(level.row("tool.sh")?.status == .unchanged && level.row("locked")?.status == .unchanged)
        }
    }

    @Test func missingParentFoldersAreCreated() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        // Drilled into docs, which exists only on the left.
        let item = try staged(fixture.left, fixture.right, "docs/guide.md", .toRight)
        let outcome = FolderCopier(leftRoot: fixture.left, rightRoot: fixture.right, items: [item],
                                   trash: DirectoryTrash(directory: fixture.directory.url.appending(path: "trash").path(percentEncoded: false))).run()
        #expect(outcome.copied == ["docs/guide.md"])
        #expect(contents(fixture.right + "/docs/guide.md") == contents(fixture.left + "/docs/guide.md"))
    }

    @Test func pathsThatLeaveTheRootAreRefused() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let entry = FolderEntry(name: "..", kind: .file, size: 0, modificationTimeNs: 0, isReadable: true, key: 1, isDeep: true)
        let item = StagedCopy(row: FolderRow(left: entry, right: nil, status: .leftOnly), levelPath: "", direction: .toRight)
        var codes: [Int32] = []
        _ = FolderCopier(leftRoot: fixture.left, rightRoot: fixture.right, items: [item],
                         trash: DirectoryTrash(directory: fixture.directory.url.appending(path: "trash").path(percentEncoded: false)))
            .run(onError: { codes.append($0.code); return .skip })
        #expect(codes == [0])
    }

    @Test func progressIsWeightedByBytesAndOrderedByName() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-progress")
        defer { directory.remove() }
        let left = try TreeBuilder(directory.url.appending(path: "left"))
        let right = try TreeBuilder(directory.url.appending(path: "right"))
        try left.file("b.txt", String(repeating: "b", count: 30_000))
        try left.file("a/one.txt", String(repeating: "a", count: 10_000))
        try right.directory("z")
        var updates: [CopyProgress] = []
        let outcome = FolderCopier(leftRoot: left.path, rightRoot: right.path,
                                   items: [try staged(left.path, right.path, "b.txt", .toRight),
                                           try staged(left.path, right.path, "a", .toRight)],
                                   trash: DirectoryTrash(directory: directory.url.appending(path: "trash").path(percentEncoded: false)),
                                   allowClone: false, chunkSize: 4096).run(progress: { updates.append($0) })
        #expect(outcome.copied == ["a", "b.txt"] && outcome.copiedBytes == 40_000)
        #expect(updates.first?.phase == .preparing)
        let copying = updates.dropFirst()
        #expect(copying.allSatisfy { $0.totalBytes == 40_000 })
        #expect(zip(copying, copying.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
        #expect(updates.last?.fraction == 1)
        #expect(updates.contains { $0.name == "b.txt" && $0.completedBytes > 10_000 && $0.completedBytes < 40_000 })
    }

    // MARK: lock and trash

    @Test func theLockRefusesOverlappingCopies() throws {
        let lock = CopyLock()
        let first = try lock.acquire(["/a/left/docs", "/a/right/docs"]).get()
        #expect(throws: CopyLockConflict(path: "/a/right")) { try lock.acquire(["/a/right"]).get() }
        #expect(throws: CopyLockConflict(path: "/a/left/docs/guide.md")) { try lock.acquire(["/a/left/docs/guide.md"]).get() }
        let other = try lock.acquire(["/a/left/docs2", "/a/right/src"]).get()
        first.release()
        #expect((try? lock.acquire(["/a/right/docs"]).get()) != nil)
        other.release()
    }

    @Test func directoryTrashNumbersDuplicateNames() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-trash")
        defer { directory.remove() }
        let tree = try TreeBuilder(directory.url.appending(path: "items"))
        let trash = DirectoryTrash(directory: directory.url.appending(path: "trash").path(percentEncoded: false))
        var places: [String?] = []
        for _ in 0..<3 {
            let file = try tree.file("notes.txt", "n")
            places.append(try trash.trash(file.path(percentEncoded: false)))
        }
        #expect(places.compactMap { $0.map { ($0 as NSString).lastPathComponent } } == ["notes.txt", "notes 2.txt", "notes 3.txt"])
    }

    /// The Finder Trash, on one temporary file; off unless asked for, and
    /// the trashed file is deleted again from the Trash.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRISM_TEST_REAL_TRASH"] == "1"))
    func systemTrashMovesOneTemporaryFile() throws {
        let directory = try TemporaryDirectory(prefix: "prism-copy-real-trash")
        defer { directory.remove() }
        let tree = try TreeBuilder(directory.url)
        let name = "prism-trash-test-\(UUID().uuidString).txt"
        let file = try tree.file(name, "trash me")
        let place = try #require(try SystemTrash().trash(file.path(percentEncoded: false)))
        #expect(!exists(file.path(percentEncoded: false)))
        #expect((place as NSString).lastPathComponent.hasPrefix("prism-trash-test-"))
        #expect(contents(place) == Data("trash me".utf8))
        try FileManager.default.removeItem(atPath: place)
        #expect(!exists(place))
    }
}
