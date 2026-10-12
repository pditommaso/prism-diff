// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation
import PrismTestSupport
import Testing
@testable import FolderCore

// Regression tests for the M9 review findings on data safety. Everything
// runs in temporary directories with a `DirectoryTrash`.

private func contents(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func flags(_ path: String) -> UInt32 {
    var info = stat()
    _ = lstat(path, &info)
    return info.st_flags
}

private func leftovers(_ root: String) -> [String] {
    (FileManager.default.subpaths(atPath: root) ?? []).filter {
        ($0 as NSString).lastPathComponent.hasPrefix(".prism-copy-")
    }
}

/// Clears user flags and write protection below `path`, so the temporary
/// directory can be removed.
private func unlockAll(_ path: String) {
    _ = Process.run("/usr/bin/chflags", ["-R", "nouchg", path])
    _ = Process.run("/bin/chmod", ["-R", "u+rwx", path])
}

extension Process {
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private func staged(_ left: String, _ right: String, _ relativePath: String, _ direction: CopyDirection) throws -> StagedCopy {
    let level = (relativePath as NSString).deletingLastPathComponent
    let name = (relativePath as NSString).lastPathComponent
    let rows = FolderSession.compare(left: left, right: right, relativePath: level).rows
    let row = try #require(rows.first { Array($0.name.utf8) == Array(name.utf8) })
    var staging = FolderStaging(levelPath: level)
    staging.set(row, direction)
    return try #require(staging.ordered.first)
}

/// A trash that always fails, to exercise the restore path.
private struct FailingTrash: TrashMover {
    func trash(_ path: String) throws -> String? { throw POSIXError(.EPERM) }
}

/// Two trees and a trash directory in one temporary directory.
private struct Pair {
    let directory: TemporaryDirectory
    let left: TreeBuilder
    let right: TreeBuilder
    var trash: String { directory.url.appending(path: "trash").path(percentEncoded: false) }

    init(_ prefix: String) throws {
        directory = try TemporaryDirectory(prefix: prefix)
        left = try TreeBuilder(directory.url.appending(path: "left"))
        right = try TreeBuilder(directory.url.appending(path: "right"))
    }

    func copier(_ items: [StagedCopy], trash: (any TrashMover)? = nil, clone: Bool = true) -> FolderCopier {
        FolderCopier(leftRoot: left.path, rightRoot: right.path, items: items,
                     trash: trash ?? DirectoryTrash(directory: self.trash), allowClone: clone)
    }

    func remove() {
        unlockAll(directory.url.path(percentEncoded: false))
        directory.remove()
    }
}

private let caseInsensitiveTemp = pathconf(NSTemporaryDirectory(), _PC_CASE_SENSITIVE) == 0

@Suite(.serialized) struct CopySafetyTests {
    // MARK: 1. the replace step never loses the destination

    @Test func lockedItemsReplaceAndKeepTheirLock() throws {
        let pair = try Pair("prism-safety-locked")
        defer { pair.remove() }
        try pair.left.file("d", "new locked file")
        try pair.right.file("d", "old", mtime: TreeBuilder.baseTime - 9)
        try pair.left.file("folder/inside.txt", "in")
        try pair.right.file("folder/old.txt", "old")
        #expect(chflags(pair.left.url("d").path(percentEncoded: false), UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(pair.left.url("folder").path(percentEncoded: false), UInt32(UF_IMMUTABLE)) == 0)
        for clone in [false, true] {
            if clone {
                // Put old copies back on the right for the second round.
                unlockAll(pair.right.path)
                try FileManager.default.removeItem(at: pair.right.url("d"))
                try FileManager.default.removeItem(at: pair.right.url("folder"))
                try pair.right.file("d", "old", mtime: TreeBuilder.baseTime - 9)
                try pair.right.file("folder/old.txt", "old")
                unlockAll(pair.trash)
                try? FileManager.default.removeItem(atPath: pair.trash)
            }
            var failures: [CopyFailure] = []
            let outcome = pair.copier([try staged(pair.left.path, pair.right.path, "d", .toRight),
                                       try staged(pair.left.path, pair.right.path, "folder", .toRight)], clone: clone)
                .run(onError: { failures.append($0); return .skip })
            #expect(failures.isEmpty, "\(failures.map(\.reason))")
            #expect(outcome.copied == ["d", "folder"])
            #expect(contents(pair.right.path + "/d") == Data("new locked file".utf8))
            #expect(flags(pair.right.path + "/d") & UInt32(UF_IMMUTABLE) != 0)
            #expect(flags(pair.right.path + "/folder") & UInt32(UF_IMMUTABLE) != 0)
            #expect(contents(pair.trash + "/d") == Data("old".utf8))
            #expect(contents(pair.trash + "/folder/old.txt") == Data("old".utf8))
            #expect(outcome.trashed.keys.sorted() == ["d", "folder"])
            #expect(leftovers(pair.right.path).isEmpty)
        }
    }

    @Test func aFailedTrashPutsTheOriginalBack() throws {
        let pair = try Pair("prism-safety-restore")
        defer { pair.remove() }
        try pair.left.file("d/new.txt", "new")
        try pair.right.file("d/old.txt", "old")
        try pair.left.file("f", "new file")
        try pair.right.file("f", "old file", mtime: TreeBuilder.baseTime - 3)
        var failures: [CopyFailure] = []
        let outcome = pair.copier([try staged(pair.left.path, pair.right.path, "d", .toRight),
                                   try staged(pair.left.path, pair.right.path, "f", .toRight)], trash: FailingTrash())
            .run(onError: { failures.append($0); return .skip })
        #expect(failures.map(\.relativePath) == ["d", "f"])
        #expect(failures.allSatisfy { $0.operation == "move to the Trash" })
        #expect(outcome.skipped == ["d", "f"] && outcome.copied.isEmpty && outcome.trashed.isEmpty)
        #expect(contents(pair.right.path + "/d/old.txt") == Data("old".utf8))
        #expect(!exists(pair.right.path + "/d/new.txt"))
        #expect(contents(pair.right.path + "/f") == Data("old file".utf8))
        #expect(leftovers(pair.right.path).isEmpty)
    }

    @Test func aLockedDestinationIsReportedAndKept() throws {
        let pair = try Pair("prism-safety-locked-dest")
        defer { pair.remove() }
        try pair.left.file("f", "new")
        try pair.right.file("f", "old", mtime: TreeBuilder.baseTime - 3)
        #expect(chflags(pair.right.url("f").path(percentEncoded: false), UInt32(UF_IMMUTABLE)) == 0)
        var failures: [CopyFailure] = []
        let item = try staged(pair.left.path, pair.right.path, "f", .toRight)
        // Retry fails the same way and leaves everything as it was.
        let outcome = pair.copier([item]).run(onError: { failures.append($0); return failures.count == 1 ? .retry : .skip })
        #expect(failures.count == 2 && failures.allSatisfy { $0.code == EPERM })
        #expect(outcome.skipped == ["f"] && outcome.trashed.isEmpty)
        #expect(contents(pair.right.path + "/f") == Data("old".utf8))
        #expect(leftovers(pair.right.path).isEmpty)
    }

    // MARK: 2. names that alias on disk

    @Test(.enabled(if: caseInsensitiveTemp)) func aCaseAliasIsNeverTrashed() throws {
        let pair = try Pair("prism-safety-case")
        defer { pair.remove() }
        try pair.left.file("Readme", "left")
        try pair.right.file("README", "right")
        let item = try staged(pair.left.path, pair.right.path, "Readme", .toRight)
        #expect(!item.replaces)
        var failures: [CopyFailure] = []
        let outcome = pair.copier([item]).run(onError: { failures.append($0); return .skip })
        #expect(failures.first?.code == EEXIST && failures.first?.failingPath.hasSuffix("/README") == true)
        #expect(failures.first?.reason.contains("differs only in case") == true)
        #expect(outcome.skipped == ["Readme"] && outcome.trashed.isEmpty)
        #expect(contents(pair.right.path + "/README") == Data("right".utf8))
        #expect(!exists(pair.trash))
        #expect(try FileManager.default.contentsOfDirectory(atPath: pair.right.path) == ["README"])
    }

    @Test func aUnicodeAliasIsNeverTrashed() throws {
        let pair = try Pair("prism-safety-nfd")
        defer { pair.remove() }
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        // POSIX calls keep the exact bytes (URL APIs may decompose names).
        func write(_ path: String, _ text: String) {
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
            close(fd)
        }
        write(pair.left.path + "/" + nfc, "left")
        write(pair.right.path + "/" + nfd, "right")
        let names = try FileManager.default.contentsOfDirectory(atPath: pair.right.path)
        guard names.first.map({ Array($0.utf8) == Array(nfd.utf8) }) == true else {
            // The volume rewrote the name: nothing aliases here.
            return
        }
        let item = try staged(pair.left.path, pair.right.path, nfc, .toRight)
        var failures: [CopyFailure] = []
        let outcome = pair.copier([item]).run(onError: { failures.append($0); return .skip })
        if exists(pair.right.path + "/" + nfc) && failures.isEmpty {
            // A normalization-sensitive volume: both names coexist.
            #expect(contents(pair.right.path + "/" + nfd) == Data("right".utf8))
            return
        }
        #expect(failures.first?.code == EEXIST)
        #expect(outcome.trashed.isEmpty)
        #expect(contents(pair.right.path + "/" + nfd) == Data("right".utf8))
    }

    @Test func anItemThatAppearedSinceStagingIsNotReplaced() throws {
        let pair = try Pair("prism-safety-appeared")
        defer { pair.remove() }
        try pair.left.file("new.txt", "left")
        try pair.right.directory("x")
        let item = try staged(pair.left.path, pair.right.path, "new.txt", .toRight)
        try pair.right.file("new.txt", "someone else's")
        var codes: [Int32] = []
        let outcome = pair.copier([item]).run(onError: { codes.append($0.code); return .skip })
        #expect(codes == [EEXIST] && outcome.trashed.isEmpty)
        #expect(contents(pair.right.path + "/new.txt") == Data("someone else's".utf8))
    }

    @Test(.enabled(if: caseInsensitiveTemp)) func theLockFoldsCaseAndUnicodeOnCaseInsensitiveVolumes() throws {
        let directory = try TemporaryDirectory(prefix: "prism-safety-lock")
        defer { directory.remove() }
        let base = FolderSession.canonical(directory.url.path(percentEncoded: false))
        let lock = CopyLock()
        let lease = try lock.acquire([base + "/README", base + "/caf\u{E9}"]).get()
        defer { lease.release() }
        #expect(throws: CopyLockConflict(path: base + "/readme")) { try lock.acquire([base + "/readme"]).get() }
        #expect(throws: CopyLockConflict(path: base + "/Cafe\u{301}/x")) { try lock.acquire([base + "/Cafe\u{301}/x"]).get() }
        #expect(lock.isHeld(base + "/ReadMe"))
        #expect(!lock.isHeld(base + "/other"))
    }

    // MARK: 3. a parent swapped for a link while copying

    @Test func aParentSwappedForALinkMidCopyNeverReachesOutside() throws {
        let pair = try Pair("prism-safety-toctou")
        defer { pair.remove() }
        let outside = try TreeBuilder(pair.directory.url.appending(path: "outside"))
        try outside.file("x", "precious")
        try pair.left.directory("sub")
        try Data(count: 8 << 20).write(to: pair.left.url("sub/x"))
        try pair.right.file("sub/x", "old")
        let item = try staged(pair.left.path, pair.right.path, "sub/x", .toRight)
        let copier = FolderCopier(leftRoot: pair.left.path, rightRoot: pair.right.path, items: [item],
                                  trash: DirectoryTrash(directory: pair.trash), allowClone: false, chunkSize: 1 << 20)
        var swapped = false
        let outcome = copier.run(progress: { progress in
            if !swapped && progress.completedBytes > 0 {
                swapped = true
                _ = rename(pair.right.path + "/sub", pair.right.path + "/sub-moved")
                _ = symlink(outside.path, pair.right.path + "/sub")
            }
        }, onError: { _ in .skip })
        #expect(swapped)
        #expect(contents(outside.path + "/x") == Data("precious".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["x"])
        #expect(leftovers(outside.path).isEmpty)
        // The copy went to the folder it opened, now under its new name.
        if outcome.copied == ["sub/x"] {
            #expect(contents(pair.right.path + "/sub-moved/x")?.count == 8 << 20)
            #expect(contents(pair.trash + "/x") == Data("old".utf8))
        }
    }

    // MARK: 5. leftovers of an interrupted copy

    @Test func staleTemporariesAreCleanedAndParkedItemsRestored() throws {
        let pair = try Pair("prism-safety-stale")
        defer { pair.remove() }
        let root = pair.right.path
        try pair.right.file(".prism-copy-AAAA1111-big.bin", "partial")
        try pair.right.file(".prism-copy-BBBB2222-tree/a/b.txt", "partial")
        // Killed after parking the old item: its name is free, so it comes back.
        try pair.right.file(".prism-copy-CCCC3333-doc.txt-old/doc.txt", "the original")
        // Killed after installing the new item: the old one goes to the trash.
        try pair.right.file("notes.txt", "new")
        try pair.right.file(".prism-copy-DDDD4444-notes.txt-old/notes.txt", "old notes")
        try pair.right.file("keep.txt", "user file")
        #expect(FolderCopier.cleanStaleTemporaries(in: root, trash: DirectoryTrash(directory: pair.trash),
                                                   minimumAge: 3600).isEmpty, "recent leftovers are left alone")
        let handled = FolderCopier.cleanStaleTemporaries(in: root, trash: DirectoryTrash(directory: pair.trash),
                                                         minimumAge: 0)
        #expect(handled.count == 4)
        #expect(leftovers(root).isEmpty)
        #expect(contents(root + "/doc.txt") == Data("the original".utf8))
        #expect(contents(root + "/notes.txt") == Data("new".utf8))
        #expect(contents(pair.trash + "/notes.txt") == Data("old notes".utf8))
        #expect(contents(root + "/keep.txt") == Data("user file".utf8))
        // A folder taking part in a running copy is skipped.
        try pair.right.file(".prism-copy-EEEE5555-busy", "in use")
        let lease = try CopyLock.shared.acquire([FolderSession.canonical(root) + "/busy"]).get()
        defer { lease.release() }
        #expect(FolderCopier.cleanStaleTemporaries(in: root, trash: DirectoryTrash(directory: pair.trash),
                                                   minimumAge: 0).isEmpty)
    }

    // MARK: 6. folders made for a failed item

    @Test func foldersCreatedForAFailedItemAreRemoved() throws {
        let pair = try Pair("prism-safety-parents")
        defer { pair.remove() }
        try pair.left.file("docs/deep/guide.md", "guide")
        try pair.right.directory("other")
        let item = try staged(pair.left.path, pair.right.path, "docs/deep/guide.md", .toRight)
        #expect(chmod(pair.left.url("docs/deep/guide.md").path(percentEncoded: false), 0o000) == 0)
        var codes: [Int32] = []
        let outcome = pair.copier([item], clone: false).run(onError: { codes.append($0.code); return .skip })
        #expect(codes == [EACCES] && outcome.skipped == ["docs/deep/guide.md"])
        #expect(!exists(pair.right.path + "/docs"))
        // Cancelled before any byte: the same.
        let cancelled = pair.copier([item], clone: false)
        cancelled.cancel()
        _ = cancelled.run()
        #expect(!exists(pair.right.path + "/docs"))
    }

    // MARK: the Finder Trash on a symbolic link

    /// Runs only when PRISM_TEST_TRASH_VOLUME names the mount point of a
    /// scratch disk image: `trashItem` then uses that volume's own trash
    /// folder (`.Trashes/<uid>`), never the user's Trash.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRISM_TEST_TRASH_VOLUME"] != nil))
    func systemTrashMovesTheLinkNotItsTarget() throws {
        let volume = try #require(ProcessInfo.processInfo.environment["PRISM_TEST_TRASH_VOLUME"])
        let base = volume + "/link-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: URL(filePath: base + "/target.txt"))
        #expect(symlink(base + "/target.txt", base + "/link") == 0)
        let place = try #require(try SystemTrash().trash(base + "/link"))
        #expect(place.hasPrefix(volume), "trashed on the scratch volume: \(place)")
        var info = stat()
        #expect(lstat(place, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK)
        #expect(!exists(base + "/link"))
        #expect(contents(base + "/target.txt") == Data("target".utf8))
        try FileManager.default.removeItem(atPath: place)
        try FileManager.default.removeItem(atPath: base)
    }
}
