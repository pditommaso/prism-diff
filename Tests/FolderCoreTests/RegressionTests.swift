// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import CoreServices
import Darwin
import Foundation
import PrismTestSupport
import Testing
@testable import FolderCore

/// Regression tests for the review findings on live refresh, rescans,
/// content checks and unreadable folders.
@Suite(.serialized) struct RegressionTests {
    func pair(_ prefix: String) throws -> (TemporaryDirectory, TreeBuilder, TreeBuilder) {
        let dir = try TemporaryDirectory(prefix: prefix)
        return (dir, try TreeBuilder(dir.url.appending(path: "L")), try TreeBuilder(dir.url.appending(path: "R")))
    }

    /// A started session with the root level observed and complete.
    func live(_ left: String, _ right: String, watch: Bool = true)
        -> (FolderSession, LevelRecorder, FolderObservation, LogLines) {
        let lines = LogLines()
        let session = FolderSession(left: left, right: right, log: { lines.append($0) })
        session.start(watch: watch)
        _ = session.waitUntilScanned(timeout: 30)
        let recorder = LevelRecorder()
        let observation = session.observe("", on: recorder.queue) { recorder.record($0) }
        _ = recorder.wait { $0.isComplete }
        return (session, recorder, observation, lines)
    }

    // 1. A folder renamed into the name of another must not inherit its digest.
    @Test func swappingTwoFoldersByRenameIsSeen() throws {
        let (dir, left, right) = try pair("prism-swap")
        defer { dir.remove() }
        for side in [left, right] {
            try side.file("a/x.txt", "1")
            try side.file("b/y.txt", "22")
        }
        let (session, recorder, observation, _) = live(left.path, right.path)
        defer { observation.cancel(); session.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let root = right.path
        #expect(rename(root + "/a", root + "/tmp") == 0)
        #expect(rename(root + "/b", root + "/a") == 0)
        #expect(rename(root + "/tmp", root + "/b") == 0)
        let expected = FolderSession.compare(left: left.path, right: right.path)
        #expect(expected.summary == ["a changed LR", "b changed LR"])
        let seen = recorder.wait(timeout: 10) { $0.rows == expected.rows }
        #expect(seen != nil, "live rows: \(recorder.all.last?.summary ?? [])")
        #expect(session.currentStatistics.fullScans == 1)
    }

    @Test func swapAppliedFromOneRootEventIsSeen() throws {
        let (dir, left, right) = try pair("prism-swap-event")
        defer { dir.remove() }
        for side in [left, right] {
            try side.file("a/x.txt", "1")
            try side.file("b/y.txt", "22")
        }
        let (session, recorder, observation, _) = live(left.path, right.path, watch: false)
        defer { observation.cancel(); session.stop() }
        let root = session.rightPath
        #expect(rename(root + "/a", root + "/tmp") == 0)
        #expect(rename(root + "/b", root + "/a") == 0)
        #expect(rename(root + "/tmp", root + "/b") == 0)
        // Only the root is re-listed: the swapped folders must be rescanned
        // because their inodes changed.
        session.applyForTesting([FolderWatcher.Event(path: root + "/a",
                                                     flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed))])
        let level = try #require(recorder.wait(timeout: 5) { $0.counts.changed == 2 })
        #expect(level.summary == ["a changed LR", "b changed LR"])
    }

    // 2. A replaced root rescans, relists file rows and keeps the batch.
    @Test func rootChangeRescansAndRelistsFilesAndKeepsTheBatch() throws {
        let (dir, left, right) = try pair("prism-rootchange")
        defer { dir.remove() }
        for side in [left, right] {
            try side.file("same.txt", "1")
            try side.file("d/z.txt", "1")
            try side.file("e/w.txt", "1")
        }
        let (session, recorder, observation, lines) = live(left.path, right.path, watch: false)
        defer { observation.cancel(); session.stop() }
        try right.file("same.txt", "longer")          // a file row at the open level
        try right.file("e/w.txt", "changed later")    // only reported by the second event
        let root = session.rightPath
        session.applyForTesting([
            FolderWatcher.Event(path: root, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)),
            FolderWatcher.Event(path: root + "/e/w.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
        ])
        #expect(session.waitUntilScanned(timeout: 10))
        let expected = FolderSession.compare(left: left.path, right: right.path)
        #expect(expected.summary == ["d unchanged LR", "e changed LR", "same.txt changed LR"])
        let seen = recorder.wait(timeout: 5) { $0.rows == expected.rows && $0.isComplete }
        #expect(seen != nil, "live rows: \(recorder.all.last?.summary ?? [])")
        #expect(session.currentStatistics.fullScans == 2)
        #expect(lines.all.contains { $0.contains("full scan started (root changed)") })
    }

    // 5. Events dropped at a root mean a full scan, counted as one.
    @Test func droppedEventsAtARootRunAFullScan() throws {
        let (dir, left, right) = try pair("prism-dropped")
        defer { dir.remove() }
        for side in [left, right] { try side.file("d/z.txt", "1") }
        let (session, recorder, observation, lines) = live(left.path, right.path, watch: false)
        defer { observation.cancel(); session.stop() }
        try right.file("d/new.txt", "n")
        session.applyForTesting([FolderWatcher.Event(path: session.rightPath,
                                                     flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))])
        #expect(session.waitUntilScanned(timeout: 10))
        let level = try #require(recorder.wait(timeout: 5) { $0.row("d")?.status == .changed })
        #expect(level.isComplete)
        let stats = session.currentStatistics
        #expect(stats.fullScans == 2)
        #expect(stats.incrementalRefreshes == 0 && stats.subtreeRescans == 0)
        #expect(lines.all.contains { $0.contains("full scan started (events dropped)") })
        #expect(!lines.all.contains { $0.contains("incremental refresh") })
    }

    // 3. Content checks run at most 8 at a time, without parking threads.
    @Test func contentChecksDoNotMultiplyThreads() throws {
        let (dir, left, right) = try pair("prism-threads")
        defer { dir.remove() }
        let blob = String(repeating: "a", count: 1 << 20)
        let seed = try left.file("seed.bin", blob)
        for index in 0..<200 {
            for (side, mtime) in [(left, TreeBuilder.baseTime), (right, TreeBuilder.baseTime + 10)] {
                let target = side.url("f\(index).bin").path(percentEncoded: false)
                #expect(clonefile(seed.path(percentEncoded: false), target, 0) == 0)
                try side.setTime("f\(index).bin", mtime)
            }
        }
        try left.remove("seed.bin")
        let baseline = Self.threadCount()
        let session = FolderSession(left: left.path, right: right.path, options: FolderOptions(compareContents: true))
        defer { session.stop() }
        session.start(watch: false)
        session.waitUntilScanned()
        let recorder = LevelRecorder()
        let observation = session.observe("", on: recorder.queue) { recorder.record($0) }
        defer { observation.cancel() }
        var peak = 0
        let deadline = Date(timeIntervalSinceNow: 60)
        while Date() < deadline {
            peak = max(peak, Self.threadCount())
            if recorder.all.last?.isComplete == true { break }
            usleep(1000)
        }
        #expect(recorder.all.last?.isComplete == true)
        #expect(recorder.all.last?.counts == FolderCounts(changed: 0, unchanged: 200, unmatched: 0))
        // 8 checks plus the parallel ranges of large files stay far below
        // one thread per pair.
        #expect(peak - baseline < 40, "threads: baseline \(baseline), peak \(peak)")
    }

    @Test func cancelledContentChecksStop() throws {
        let dir = try TemporaryDirectory(prefix: "prism-cancel-content")
        defer { dir.remove() }
        let bytes = Data(repeating: 1, count: 4 << 20)
        let a = dir.url.appending(path: "a"), b = dir.url.appending(path: "b")
        try bytes.write(to: a)
        try bytes.write(to: b)
        #expect(ContentCompare.sameFile(a.path(percentEncoded: false), b.path(percentEncoded: false)))
        let cancelled: @Sendable () -> Bool = { true }
        let verdict = ContentCompare.sameFile(a.path(percentEncoded: false), b.path(percentEncoded: false), cancelled: cancelled)
        #expect(!verdict)
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    // 4. A folder that cannot be listed is reported, not shown as empty.
    @Test func unreadableFolderIsFlaggedNotEmpty() throws {
        guard geteuid() != 0 else { return }
        let (dir, left, right) = try pair("prism-unreadable")
        defer {
            chmod(left.url("none").path(percentEncoded: false), 0o755)
            chmod(left.url("noexec").path(percentEncoded: false), 0o755)
            dir.remove()
        }
        for side in [left, right] {
            try side.file("none/h.txt", "1")
            try side.file("noexec/g.txt", "1")
        }
        chmod(left.url("none").path(percentEncoded: false), 0)
        chmod(left.url("noexec").path(percentEncoded: false), 0o644)
        for method in [ScanMethod.automatic, .bulk, .fts] {
            let level = FolderSession.compare(left: left.path, right: right.path, relativePath: "none",
                                              options: FolderOptions(method: method))
            #expect(level.leftUnreadable && !level.leftMissing, "\(method)")
            #expect(!level.rightUnreadable)
        }
        let readable = FolderSession.compare(left: left.path, right: right.path)
        #expect(!readable.leftUnreadable && !readable.rightUnreadable)
        // Readable but not searchable: names still come through (fts
        // fallback), so the item is not shown as right-only.
        let noexec = FolderSession.compare(left: left.path, right: right.path, relativePath: "noexec")
        #expect(noexec.row("g.txt")?.left != nil, "rows: \(noexec.summary)")
    }

    // 6. Changes between the first listing and start() are not missed.
    @Test func changesBeforeStartAreSeen() throws {
        let (dir, left, right) = try pair("prism-before-start")
        defer { dir.remove() }
        for side in [left, right] { try side.file("d/z.txt", "1") }
        let session = FolderSession(left: left.path, right: right.path)
        defer { session.stop() }
        let recorder = LevelRecorder()
        let observation = session.observe("d", on: recorder.queue) { recorder.record($0) }
        defer { observation.cancel() }
        _ = recorder.wait { _ in true }
        let recorded = try #require(session.streamStartEventID)
        #expect(recorded <= FSEventsGetCurrentEventId())
        try right.file("d/early.txt", "e")
        session.start()
        let level = recorder.wait(timeout: 10) { $0.isComplete && $0.row("early.txt") != nil }
        #expect(level?.row("early.txt")?.status == .rightOnly)
    }
}
