// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol

/// Private copies of temporary files, made before `prism` gets its reply
/// so that the calling tool may delete the originals right away.
///
/// Each request gets its own folder under `root`; a file keeps its name
/// inside a numbered subfolder, so that the copy still shows the original
/// file name. Folders are removed with their document, and `root` as a
/// whole by `removeAll()`.
public struct SnapshotStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    static let folderPrefix = "\(PrismInfo.bundleIdentifier).snapshots-"

    /// A store in a per-process folder under the temporary directory.
    public static func temporary(in parent: URL = FileManager.default.temporaryDirectory) -> SnapshotStore {
        SnapshotStore(root: parent.appending(path: "\(folderPrefix)\(getpid())", directoryHint: .isDirectory))
    }

    /// Deletes the snapshot folders of earlier app processes that are no
    /// longer running (left behind by a crash or a forced quit). Returns
    /// the folders removed.
    @discardableResult
    public static func removeStale(in parent: URL = FileManager.default.temporaryDirectory) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return [] }
        var removed: [URL] = []
        for name in names where name.hasPrefix(folderPrefix) {
            guard let pid = Int32(name.dropFirst(folderPrefix.count)), pid != getpid() else { continue }
            if kill(pid, 0) == 0 || errno != ESRCH { continue }     // still running (or not ours to judge)
            let folder = parent.appending(path: name, directoryHint: .isDirectory)
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed.append(folder) }
        }
        return removed
    }

    public struct Failure: Error, CustomStringConvertible {
        public let path: String
        public let reason: String
        public var description: String { "cannot copy \(path): \(reason)" }
    }

    /// The comparison files of `lists`, copying every temporary one. Returns
    /// the request folder (nil when nothing was copied).
    public func resolve(_ lists: [FileList]) throws(Failure) -> (files: [[ComparisonFile]], folder: URL?) {
        let fileManager = FileManager.default
        var folder: URL?
        var result: [[ComparisonFile]] = []
        var counter = 0
        for list in lists {
            var files: [ComparisonFile] = []
            for reference in list.files {
                // Only regular files are copied: a folder (or a device, a
                // pipe) is read where it is.
                let exists = FileManager.default.fileExists(atPath: reference.path)
                guard reference.temporary, !reference.isPlaceholder, !exists || Self.isRegularFile(reference.path) else {
                    files.append(ComparisonFile(originalPath: reference.path, path: reference.path, isSnapshot: false))
                    continue
                }
                if folder == nil {
                    folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                }
                let slot = folder!.appending(path: String(counter), directoryHint: .isDirectory)
                counter += 1
                let name = (reference.path as NSString).lastPathComponent
                let copy = slot.appending(path: name, directoryHint: .notDirectory)
                do {
                    try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
                    try fileManager.copyItem(atPath: reference.path, toPath: copy.path)
                } catch {
                    if let folder { try? fileManager.removeItem(at: folder) }
                    throw Failure(path: reference.path, reason: (error as NSError).localizedDescription)
                }
                files.append(ComparisonFile(originalPath: reference.path, path: copy.path, isSnapshot: true))
            }
            result.append(files)
        }
        return (result, folder)
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Deletes one request folder.
    public func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes every copy.
    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}
