// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation
import PrismTestSupport
@testable import FolderCore

/// Builds small folder trees with exact sizes and modification times.
struct TreeBuilder {
    let root: URL

    var path: String { root.path(percentEncoded: false) }

    /// A fixed time, so that two trees built alike compare equal.
    static let baseTime: Int64 = 1_791_000_000

    init(_ root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relative: String) -> URL { root.appending(path: relative) }

    @discardableResult
    func file(_ relative: String, _ contents: String = "x", mtime: Int64 = baseTime) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try setTime(relative, mtime)
        return url
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    func symlink(_ relative: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(relative).path(percentEncoded: false),
                                                   withDestinationPath: target)
    }

    func setTime(_ relative: String, _ seconds: Int64, nanoseconds: Int = 0) throws {
        var times = [timespec(tv_sec: Int(seconds), tv_nsec: nanoseconds),
                     timespec(tv_sec: Int(seconds), tv_nsec: nanoseconds)]
        guard utimensat(AT_FDCWD, url(relative).path(percentEncoded: false), &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: url(relative))
    }
}

/// A scratch copy of `Tests/corpus/fixtures/folders/{left,right}` with fixed
/// modification times: git does not keep them, and README.md must be equal
/// on both sides (same bytes and same time).
struct FolderFixture {
    let directory: TemporaryDirectory
    let left: String
    let right: String

    static let readmeTime: Int64 = 1_577_836_800       // 2020-01-01 00:00:00 UTC
    static let defaultTime: Int64 = 1_791_729_989      // 2026-10-11 14:46:29 UTC

    init() throws {
        directory = try TemporaryDirectory(prefix: "prism-folders")
        let source = Corpus.directory.appending(path: "fixtures/folders", directoryHint: .isDirectory)
        for side in ["left", "right"] {
            let from = source.appending(path: side, directoryHint: .isDirectory)
            let to = directory.url.appending(path: side, directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: from, to: to)
            try Self.stamp(to)
        }
        left = directory.url.appending(path: "left").path(percentEncoded: false)
        right = directory.url.appending(path: "right").path(percentEncoded: false)
    }

    func remove() { directory.remove() }

    /// Sets every item's time: README.md to `readmeTime`, the rest to
    /// `defaultTime` (deepest items first, so directory times stick).
    static func stamp(_ root: URL) throws {
        let fileManager = FileManager.default
        var paths: [String] = []
        if let enumerator = fileManager.enumerator(atPath: root.path(percentEncoded: false)) {
            while let item = enumerator.nextObject() as? String { paths.append(item) }
        }
        for relative in paths.sorted(by: { $0.count > $1.count }) + [""] {
            let full = relative.isEmpty ? root.path(percentEncoded: false) : root.appending(path: relative).path(percentEncoded: false)
            if relative.hasSuffix(".DS_Store") { continue }
            let seconds = relative == "README.md" ? readmeTime : defaultTime
            var times = [timespec(tv_sec: Int(seconds), tv_nsec: 0), timespec(tv_sec: Int(seconds), tv_nsec: 0)]
            _ = utimensat(AT_FDCWD, full, &times, AT_SYMLINK_NOFOLLOW)
        }
    }
}

/// Collects level updates from a session on a private queue.
final class LevelRecorder: @unchecked Sendable {
    private let lock = NSCondition()
    private var levels: [FolderLevel] = []
    let queue = DispatchQueue(label: "level-recorder")

    func record(_ level: FolderLevel) {
        lock.lock()
        levels.append(level)
        lock.broadcast()
        lock.unlock()
    }

    var all: [FolderLevel] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }

    /// Waits for an update satisfying `predicate`; nil on timeout.
    func wait(timeout: TimeInterval = 10, _ predicate: (FolderLevel) -> Bool) -> FolderLevel? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let match = levels.last(where: predicate) { return match }
            if !lock.wait(until: deadline) { return levels.last(where: predicate) }
        }
    }
}

extension FolderLevel {
    /// "name status" lines, for readable expectations.
    var summary: [String] {
        rows.map { row in
            let sides = (row.left == nil ? "-" : "L") + (row.right == nil ? "-" : "R")
            return "\(row.name) \(row.status.rawValue) \(sides)"
        }
    }

    func row(_ name: String) -> FolderRow? { rows.first { $0.name == name } }
}
