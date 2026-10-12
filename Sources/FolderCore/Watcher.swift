// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import CoreServices
import Foundation

/// A file-level FSEvents stream over the two comparison roots.
final class FolderWatcher: @unchecked Sendable {
    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        var mustRescanSubtree: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
        }

        var rootChanged: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }

        var historyDone: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 }
    }

    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([Event]) -> Void

    /// Starts watching `paths`; `handler` runs on `queue` with each batch.
    /// Returns nil when the stream cannot be created or started.
    /// `since` is the event ID to replay from (or SinceNow).
    init?(paths: [String], since: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
          latency: Double, queue: DispatchQueue, handler: @escaping @Sendable ([Event]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                events.append(Event(path: String(cString: cPaths[index]), flags: flags[index]))
            }
            watcher.handler(events)
        }
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               since, latency, createFlags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Stops the stream. Must be called on the stream's queue (or after it
    /// is idle) before the watcher is released.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
