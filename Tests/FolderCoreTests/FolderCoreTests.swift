// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation
import PrismTestSupport
import Testing
@testable import FolderCore

@Test func folderCoreModuleIsLinked() {
    #expect(FolderCore.moduleName == "FolderCore")
}

/// The committed fixture pair: rows, alignment, counts and drill-down.
@Suite struct FixtureComparisonTests {
    @Test func rootLevelMatchesTheFixturePlan() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let level = FolderSession.compare(left: fixture.left, right: fixture.right)
        #expect(level.summary == [
            "assets right-only -R",
            "CHANGELOG.md right-only -R",
            "docs left-only L-",
            "LICENSE left-only L-",
            "README.md unchanged LR",
            "src changed LR",
        ])
        #expect(level.counts == FolderCounts(changed: 1, unchanged: 1, unmatched: 4))
        #expect(level.isComplete)
        #expect(level.rows.allSatisfy { !$0.isPending })
        // Folder sizes are the totals of their files.
        #expect(level.row("src")?.left?.size == 407 + 11)
        #expect(level.row("src")?.right?.size == 463 + 16)
        #expect(level.row("docs")?.left?.size == 10)
    }

    @Test func drillingIntoSourceShowsTwoChanges() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let level = FolderSession.compare(left: fixture.left, right: fixture.right, relativePath: "src")
        #expect(level.summary == ["main.swift changed LR", "util changed LR"])
        #expect(level.counts == FolderCounts(changed: 2, unchanged: 0, unmatched: 0))
        let util = FolderSession.compare(left: fixture.left, right: fixture.right, relativePath: "src/util")
        #expect(util.summary == ["helper.swift changed LR"])
    }

    @Test func drillingIntoAOneSidedFolderShowsOneSide() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let level = FolderSession.compare(left: fixture.left, right: fixture.right, relativePath: "docs")
        #expect(level.summary == ["guide.md left-only L-"])
        #expect(level.rightMissing && !level.leftMissing)
    }

    @Test func bulkAndFTSAgree() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        for path in ["", "src", "src/util"] {
            let bulk = FolderSession.compare(left: fixture.left, right: fixture.right, relativePath: path,
                                             options: FolderOptions(method: .bulk))
            let fts = FolderSession.compare(left: fixture.left, right: fixture.right, relativePath: path,
                                            options: FolderOptions(method: .fts))
            #expect(bulk.rows == fts.rows, "level '\(path)'")
        }
    }
}

@Suite struct EditScriptTests {
    /// Length of the longest common subsequence, by dynamic programming.
    static func lcs(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }

    @Test func scriptIsMinimalAndValidOnSortedUniqueKeys() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            // Both sides draw sorted, unique keys from one ordered universe,
            // as sorted listings of one level do.
            let universe = Array(0..<UInt64(Int.random(in: 0...40, using: &generator)))
            let a = universe.filter { _ in Bool.random(using: &generator) }
            let b = universe.filter { _ in Bool.random(using: &generator) }
            let hunks = EditScript.hunks(a, b)
            var i = 0, j = 0, equal = 0
            var rebuiltB: [UInt64] = []
            for hunk in hunks {
                #expect(hunk.a.lowerBound == i && hunk.b.lowerBound == j)
                switch hunk.kind {
                case .equal:
                    #expect(Array(a[hunk.a]) == Array(b[hunk.b]))
                    rebuiltB += b[hunk.b]
                    equal += hunk.a.count
                case .delete: #expect(hunk.b.isEmpty)
                case .insert:
                    #expect(hunk.a.isEmpty)
                    rebuiltB += b[hunk.b]
                }
                i = hunk.a.upperBound
                j = hunk.b.upperBound
            }
            #expect(i == a.count && j == b.count && rebuiltB == b)
            #expect(equal == Self.lcs(a, b))
        }
    }

    @Test func outOfOrderPartnerStaysUnmatched() {
        let hunks = EditScript.hunks([1, 2, 3], [3, 1])
        let equal = hunks.filter { $0.kind == .equal }.map(\.a.count).reduce(0, +)
        #expect(equal == 1)
    }
}

@Suite struct PairingAndStatusTests {
    func entry(_ name: String, _ kind: EntryKind = .file, key: UInt64, mtime: Int64 = 0) -> FolderEntry {
        FolderEntry(name: name, kind: kind, size: 1, modificationTimeNs: mtime, isReadable: true, key: key, isDeep: true)
    }

    @Test func namesDifferingOnlyInCaseDoNotPair() {
        let rows = FolderRows.build(left: [entry("Foo", key: 1)], right: [entry("foo", key: 2)])
        #expect(rows.count == 2 && Set(rows.map(\.status)) == [.leftOnly, .rightOnly])
    }

    @Test func aFileAndAFolderWithTheSameNamePairAsChanged() {
        let rows = FolderRows.build(left: [entry("x", key: 1)], right: [entry("x", .directory, key: 2)])
        #expect(rows.count == 1 && rows[0].status == .changed)
        #expect(!rows[0].isFolderPair)
    }

    @Test func newerSideFollowsModificationTime() {
        let rows = FolderRows.build(left: [entry("a", key: 1, mtime: 5), entry("b", key: 3, mtime: 9), entry("c", key: 5, mtime: 1)],
                                    right: [entry("a", key: 2, mtime: 7), entry("b", key: 4, mtime: 2), entry("c", key: 6, mtime: 1)])
        #expect(rows.map(\.newer) == [.right, .left, .none])
    }

    @Test func finderOrderIsNumericAndCaseInsensitive() {
        let names = ["file10", "File2", "file1", "b", "A"]
        let sorted = FinderOrder.sorted(names.enumerated().map { entry($0.element, key: UInt64($0.offset)) }).map(\.name)
        #expect(sorted == ["A", "b", "file1", "File2", "file10"])
    }

    @Test func filtersHideRowsButCountsCoverAll() {
        let rows = FolderRows.build(left: [entry("same", key: 1), entry("diff", key: 2), entry("lonely", key: 3)],
                                    right: [entry("same", key: 1), entry("diff", key: 4), entry("new", key: 5)])
        #expect(FolderCounts(rows) == FolderCounts(changed: 1, unchanged: 1, unmatched: 2))
        #expect(FolderRows.filtered(rows, .changed).map(\.name) == ["diff"])
        #expect(FolderRows.filtered(rows, .unchanged).map(\.name) == ["same"])
        #expect(FolderRows.filtered(rows, .unmatched).map(\.name) == ["lonely", "new"])
        #expect(FolderRows.filtered(rows, [.changed, .unmatched]).count == 3)
        #expect(FolderRows.filtered(rows, []).count == 4)
        #expect(FolderRows.filtered(rows, .all).count == 4)
    }

    @Test func sortingByDateAndSizeUsesTheChosenSide() {
        func sized(_ name: String, _ size: UInt64, _ mtime: Int64, key: UInt64) -> FolderEntry {
            FolderEntry(name: name, kind: .file, size: size, modificationTimeNs: mtime, isReadable: true, key: key, isDeep: true)
        }
        let rows = FolderRows.build(left: [sized("a", 30, 1, key: 1), sized("b", 10, 3, key: 2)],
                                    right: [sized("a", 5, 9, key: 3), sized("b", 20, 2, key: 4), sized("c", 15, 5, key: 5)])
        #expect(FolderRows.sorted(rows, by: FolderSort(key: .size, side: .left)).map(\.name) == ["b", "c", "a"])
        #expect(FolderRows.sorted(rows, by: FolderSort(key: .size, side: .right)).map(\.name) == ["a", "c", "b"])
        #expect(FolderRows.sorted(rows, by: FolderSort(key: .date, side: .right, ascending: false)).map(\.name) == ["a", "c", "b"])
        #expect(FolderRows.sorted(rows, by: FolderSort(key: .name, ascending: false)).map(\.name) == ["c", "b", "a"])
    }
}

@Suite struct ScanRuleTests {
    func pair() throws -> (TemporaryDirectory, TreeBuilder, TreeBuilder) {
        let dir = try TemporaryDirectory(prefix: "prism-folder-rules")
        return (dir, try TreeBuilder(dir.url.appending(path: "L")), try TreeBuilder(dir.url.appending(path: "R")))
    }

    @Test func dsStoreIsAlwaysExcludedAndHiddenItemsAreOptional() throws {
        let (dir, left, right) = try pair()
        defer { dir.remove() }
        try left.file("a.txt")
        try right.file("a.txt")
        try left.file(".DS_Store", "one")
        try right.file(".DS_Store", "two two")
        try left.file(".env", "secret")
        try left.file("flagged.txt")
        #expect(chflags(left.url("flagged.txt").path(percentEncoded: false), UInt32(UF_HIDDEN)) == 0)
        try left.file("sub/.DS_Store", "deep")
        try right.directory("sub")
        try left.setTime("sub", TreeBuilder.baseTime)

        let plain = FolderSession.compare(left: left.path, right: right.path)
        #expect(plain.summary == ["a.txt unchanged LR", "sub unchanged LR"])
        let hidden = FolderSession.compare(left: left.path, right: right.path,
                                           options: FolderOptions(includeHidden: true))
        #expect(hidden.summary == [".env left-only L-", "a.txt unchanged LR", "flagged.txt left-only L-",
                                   "sub unchanged LR"])
    }

    @Test func symlinksCompareByNameAndShowTheTargetSize() throws {
        let (dir, left, right) = try pair()
        defer { dir.remove() }
        try left.file("target-a.txt", "12345")
        try right.file("target-a.txt", "12345")
        try left.file("other.txt", "123456789")
        try right.file("other.txt", "123456789")
        try left.symlink("link", to: "target-a.txt")
        try right.symlink("link", to: "other.txt")
        try left.directory("d")
        try right.directory("d")
        try left.symlink("d/inner", to: "../target-a.txt")
        try right.symlink("d/inner", to: "/nonexistent")
        let level = FolderSession.compare(left: left.path, right: right.path)
        #expect(level.row("link")?.status == .unchanged)
        #expect(level.row("link")?.left?.size == 5)
        #expect(level.row("link")?.right?.size == 9)
        #expect(level.row("link")?.left?.kind == .symlink)
        #expect(level.row("d")?.status == .unchanged)
    }

    @Test func aliasesCompareByName() throws {
        let (dir, left, right) = try pair()
        defer { dir.remove() }
        try left.file("shortcut", "alias data one")
        try right.file("shortcut", "different alias bytes")
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x80   // kIsAlias in the big-endian Finder flags
        for side in [left, right] {
            let status = setxattr(side.url("shortcut").path(percentEncoded: false), "com.apple.FinderInfo", info, 32, 0, 0)
            #expect(status == 0)
        }
        let level = FolderSession.compare(left: left.path, right: right.path, options: FolderOptions(method: .bulk))
        #expect(level.row("shortcut")?.left?.kind == .alias)
        #expect(level.row("shortcut")?.status == .unchanged)
    }

    @Test func unreadableItemsCompareByName() throws {
        guard geteuid() != 0 else { return }
        let (dir, left, right) = try pair()
        defer {
            chmod(left.url("locked.txt").path(percentEncoded: false), 0o644)
            chmod(right.url("locked.txt").path(percentEncoded: false), 0o644)
            dir.remove()
        }
        try left.file("locked.txt", "short", mtime: 1)
        try right.file("locked.txt", "much longer text", mtime: 2)
        chmod(left.url("locked.txt").path(percentEncoded: false), 0)
        chmod(right.url("locked.txt").path(percentEncoded: false), 0)
        for method in [ScanMethod.bulk, .fts] {
            let level = FolderSession.compare(left: left.path, right: right.path, options: FolderOptions(method: method))
            #expect(level.row("locked.txt")?.status == .unchanged, "\(method)")
            #expect(level.row("locked.txt")?.left?.isReadable == false)
        }
    }

    @Test func filesCompareBySizeAndTimeNotContents() throws {
        let (dir, left, right) = try pair()
        defer { dir.remove() }
        try left.file("silent.txt", "aaaa")
        try right.file("silent.txt", "bbbb")             // same size and time, different bytes
        try left.file("touched.txt", "same")
        try right.file("touched.txt", "same", mtime: TreeBuilder.baseTime + 60)
        try left.file("nanos.txt", "same")
        try right.file("nanos.txt", "same")
        try right.setTime("nanos.txt", TreeBuilder.baseTime, nanoseconds: 1)
        let level = FolderSession.compare(left: left.path, right: right.path)
        #expect(level.row("silent.txt")?.status == .unchanged)
        #expect(level.row("touched.txt")?.status == .changed)
        #expect(level.row("touched.txt")?.newer == .right)
        #expect(level.row("nanos.txt")?.status == .changed)
    }

    @Test func compareContentsConfirmsTouchedFilesAndFolders() throws {
        let (dir, left, right) = try pair()
        defer { dir.remove() }
        try left.file("touched.txt", "same")
        try right.file("touched.txt", "same", mtime: TreeBuilder.baseTime + 60)
        try left.file("edited.txt", "aaaa")
        try right.file("edited.txt", "bbbb", mtime: TreeBuilder.baseTime + 60)
        try left.file("tree/a/one.txt", "1")
        try right.file("tree/a/one.txt", "1", mtime: TreeBuilder.baseTime + 5)
        try left.file("tree2/x.txt", "1")
        try right.file("tree2/x.txt", "2", mtime: TreeBuilder.baseTime + 5)
        let options = FolderOptions(compareContents: true)
        let level = FolderSession.compare(left: left.path, right: right.path, options: options)
        #expect(level.isComplete)
        #expect(level.row("touched.txt")?.status == .unchanged)
        #expect(level.row("edited.txt")?.status == .changed)
        #expect(level.row("tree")?.status == .unchanged)
        #expect(level.row("tree2")?.status == .changed)
        // Off by default: metadata decides.
        let plain = FolderSession.compare(left: left.path, right: right.path)
        #expect(plain.row("touched.txt")?.status == .changed)
        #expect(plain.row("tree")?.status == .changed)
    }

    @Test func largeFilesCompareInParallelRanges() throws {
        let dir = try TemporaryDirectory(prefix: "prism-content")
        defer { dir.remove() }
        var bytes = [UInt8](repeating: 7, count: 40 << 20)
        let a = dir.url.appending(path: "a"), b = dir.url.appending(path: "b")
        try Data(bytes).write(to: a)
        try Data(bytes).write(to: b)
        #expect(ContentCompare.sameFile(a.path(percentEncoded: false), b.path(percentEncoded: false)))
        bytes[bytes.count - 3] = 8
        try Data(bytes).write(to: b)
        #expect(!ContentCompare.sameFile(a.path(percentEncoded: false), b.path(percentEncoded: false)))
    }
}

@Suite struct DigestTests {
    @Test func subtreeDigestIgnoresCreationOrder() throws {
        let dir = try TemporaryDirectory(prefix: "prism-digest")
        defer { dir.remove() }
        let left = try TreeBuilder(dir.url.appending(path: "L"))
        let right = try TreeBuilder(dir.url.appending(path: "R"))
        let files = (0..<60).map { "pkg/d\($0 % 7)/sub\($0 % 3)/f\($0).txt" }
        for file in files { try left.file(file, String(repeating: "x", count: files.firstIndex(of: file)! + 1)) }
        for file in files.reversed() { try right.file(file, String(repeating: "x", count: files.firstIndex(of: file)! + 1)) }
        let level = FolderSession.compare(left: left.path, right: right.path)
        #expect(level.row("pkg")?.status == .unchanged)
        #expect(level.row("pkg")?.left?.size == UInt64((1...60).reduce(0, +)))
        #expect(level.row("pkg")?.left?.descendantCount == 60 + 7 + 21)

        // One deep change makes every ancestor differ.
        try right.setTime(files[17], TreeBuilder.baseTime + 1)
        let changed = FolderSession.compare(left: left.path, right: right.path)
        #expect(changed.row("pkg")?.status == .changed)
        let inner = FolderSession.compare(left: left.path, right: right.path, relativePath: "pkg/d3")
        #expect(inner.summary == ["sub0 unchanged LR", "sub1 unchanged LR", "sub2 changed LR"])
    }

    @Test func emptyFolderDiffersFromAFolderWithAnEmptySubfolder() throws {
        let dir = try TemporaryDirectory(prefix: "prism-digest-empty")
        defer { dir.remove() }
        let left = try TreeBuilder(dir.url.appending(path: "L"))
        let right = try TreeBuilder(dir.url.appending(path: "R"))
        try left.directory("x")
        try right.directory("x/y")
        let level = FolderSession.compare(left: left.path, right: right.path)
        #expect(level.row("x")?.status == .changed)
    }

    @Test func sizeFormatUsesDecimalUnits() {
        #expect(FolderFormat.size(0) == "0 bytes")
        #expect(FolderFormat.size(1) == "1 byte")
        #expect(FolderFormat.size(999) == "999 bytes")
        #expect(FolderFormat.size(1000) == "1 KB")
        #expect(FolderFormat.size(12_400) == "12 KB")
        #expect(FolderFormat.size(2_500_000) == "3 MB")
        #expect(FolderFormat.size(7_000_000_000) == "7 GB")
    }
}

/// A generated tree of a few thousand items: every scanning path agrees.
@Suite struct GeneratedTreeTests {
    static func build(_ root: TreeBuilder, seed: Int) throws {
        var state = UInt64(seed)
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        for index in 0..<3000 {
            let path = "t\(index % 9)/a\(next() % 12)/b\(next() % 6)/f\(index).dat"
            try root.file(path, String(repeating: "z", count: next() % 300), mtime: TreeBuilder.baseTime + Int64(index))
        }
    }

    @Test func serialParallelBulkAndFTSScansAgree() throws {
        let dir = try TemporaryDirectory(prefix: "prism-generated")
        defer { dir.remove() }
        let left = try TreeBuilder(dir.url.appending(path: "L"))
        let right = try TreeBuilder(dir.url.appending(path: "R"))
        try Self.build(left, seed: 1)
        try Self.build(right, seed: 1)
        try right.file("t4/a1/new.txt", "n")
        try right.setTime("t7/a0/b0", TreeBuilder.baseTime)   // a folder's own time does not count
        var results: [[FolderRow]] = []
        for (method, workers) in [(ScanMethod.bulk, 1), (.bulk, 8), (.fts, 1), (.fts, 6)] {
            let level = FolderSession.compare(left: left.path, right: right.path,
                                              options: FolderOptions(method: method, workers: workers))
            #expect(level.isComplete)
            results.append(level.rows)
        }
        #expect(results.allSatisfy { $0 == results[0] })
        let level = FolderSession.compare(left: left.path, right: right.path)
        #expect(level.counts == FolderCounts(changed: 1, unchanged: 8, unmatched: 0))
        #expect(level.row("t4")?.status == .changed)
        #expect(level.row("t7")?.status == .unchanged)
    }
}
