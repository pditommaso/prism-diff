// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation
import PrismTestSupport
import Testing
@testable import FolderCore

/// The session: shallow rows first, the deep pass, and live refresh.
@Suite(.serialized) struct SessionTests {
    @Test func shallowRowsComeFirstThenTheDeepPassResolvesThem() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let session = FolderSession(left: fixture.left, right: fixture.right)
        defer { session.stop() }
        let recorder = LevelRecorder()
        let observation = session.observe("", on: recorder.queue) { recorder.record($0) }
        defer { observation.cancel() }
        let first = try #require(recorder.wait { _ in true })
        #expect(!first.isComplete)
        #expect(first.row("src")?.isPending == true)
        #expect(first.row("README.md")?.isPending == false)
        session.start(watch: false)
        let done = try #require(recorder.wait { $0.isComplete })
        #expect(done.counts == FolderCounts(changed: 1, unchanged: 1, unmatched: 4))
        #expect(done.generation > first.generation)
        #expect(session.currentStatistics.fullScans == 1)
    }

    @Test func touchingAFileUpdatesItsRowWithoutAFullRescan() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let lines = LogLines()
        let session = FolderSession(left: fixture.left, right: fixture.right, log: { lines.append($0) })
        defer { session.stop() }
        session.start()
        #expect(session.waitUntilScanned(timeout: 30))
        let recorder = LevelRecorder()
        let root = session.observe("", on: recorder.queue) { recorder.record($0) }
        defer { root.cancel() }
        let src = session.observe("src", on: recorder.queue) { recorder.record($0) }
        defer { src.cancel() }
        _ = try #require(recorder.wait { $0.relativePath == "" && $0.isComplete })
        let before = try #require(recorder.wait { $0.relativePath == "src" && $0.isComplete })
        let oldTime = try #require(before.row("main.swift")?.right?.modificationTimeNs)
        // FSEvents needs a moment after the stream starts.
        Thread.sleep(forTimeInterval: 0.3)

        let touched = Date()
        let url = URL(filePath: fixture.right).appending(path: "src/main.swift")
        #expect(utimes(url.path(percentEncoded: false), nil) == 0)
        let after = try #require(recorder.wait(timeout: 5) {
            $0.relativePath == "src" && ($0.row("main.swift")?.right?.modificationTimeNs ?? 0) != oldTime
        })
        let elapsed = Date().timeIntervalSince(touched)
        #expect(elapsed < 2, "row updated after \(elapsed) s")
        #expect(after.row("main.swift")?.newer == .right)
        let stats = session.currentStatistics
        #expect(stats.fullScans == 1)
        #expect(stats.incrementalRefreshes >= 1)
        #expect(lines.all.contains { $0.contains("incremental refresh") && $0.contains("no full rescan") })
        #expect(lines.all.filter { $0.contains("full scan started") }.count == 1)
    }

    @Test func incrementalTreeMatchesAFullRescan() throws {
        let dir = try TemporaryDirectory(prefix: "prism-live")
        defer { dir.remove() }
        let left = try TreeBuilder(dir.url.appending(path: "L"))
        let right = try TreeBuilder(dir.url.appending(path: "R"))
        for builder in [left, right] {
            for index in 0..<40 { try builder.file("top\(index % 4)/mid\(index % 5)/f\(index).txt", "\(index)") }
            try builder.file("root.txt", "root")
        }
        let session = FolderSession(left: left.path, right: right.path)
        defer { session.stop() }
        session.start()
        #expect(session.waitUntilScanned(timeout: 30))
        let recorder = LevelRecorder()
        let observation = session.observe("", on: recorder.queue) { recorder.record($0) }
        defer { observation.cancel() }
        let initial = try #require(recorder.wait { $0.isComplete })
        #expect(initial.counts == FolderCounts(changed: 0, unchanged: 5, unmatched: 0))
        Thread.sleep(forTimeInterval: 0.3)

        // Edits of every kind: modify, create, delete, new folder tree,
        // removed folder tree, a hidden file (ignored) and .DS_Store.
        try right.file("top1/mid2/f6.txt", "changed contents")
        try right.file("top2/mid3/brand-new.txt", "new")
        try right.remove("top3/mid0/f15.txt")
        try right.file("top0/fresh/deeper/x.txt", "x")
        try right.remove("top1/mid1")
        try right.file("top2/.hidden", "h")
        try right.file("top2/.DS_Store", "d")
        try right.file("added-root.txt", "a")

        let expected = FolderSession.compare(left: left.path, right: right.path)
        let live = try #require(recorder.wait(timeout: 10) { $0.rows == expected.rows })
        #expect(live.summary == expected.summary)
        #expect(live.summary.contains("added-root.txt right-only -R"))
        #expect(session.currentStatistics.fullScans == 1)
        // Drill-down levels opened later use the patched tree too.
        for path in ["top0", "top1", "top2", "top3", "top0/fresh"] {
            #expect(session.level(path).rows == FolderSession.compare(left: left.path, right: right.path, relativePath: path).rows,
                    "level \(path)")
        }

        // Removing and recreating an observed level relists it.
        let top2 = LevelRecorder()
        let top2Observation = session.observe("top2", on: top2.queue) { top2.record($0) }
        defer { top2Observation.cancel() }
        _ = try #require(top2.wait { $0.isComplete })
        try right.remove("top2")
        try right.file("top2/only.txt", "o")
        let recreated = try #require(top2.wait(timeout: 10) { $0.row("only.txt") != nil && $0.row("mid0")?.right == nil })
        #expect(recreated.row("only.txt")?.status == .rightOnly)
        #expect(session.currentStatistics.fullScans == 1)
    }

    @Test func eventsDuringTheDeepPassAreApplied() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let session = FolderSession(left: fixture.left, right: fixture.right)
        defer { session.stop() }
        let recorder = LevelRecorder()
        let observation = session.observe("", on: recorder.queue) { recorder.record($0) }
        defer { observation.cancel() }
        session.start()
        try "new".write(toFile: fixture.right + "/late.txt", atomically: false, encoding: .utf8)
        let level = try #require(recorder.wait(timeout: 10) { $0.isComplete && $0.row("late.txt") != nil })
        #expect(level.row("late.txt")?.status == .rightOnly)
    }

    @Test func stopDropsObservers() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let session = FolderSession(left: fixture.left, right: fixture.right)
        session.start()
        session.stop()
        #expect(session.waitUntilScanned(timeout: 10))
    }
}

/// Thread-safe log collector.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }

    var all: [String] { lock.withLock { lines } }
}
