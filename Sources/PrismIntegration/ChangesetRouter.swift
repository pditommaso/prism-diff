// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import os
import PrismProtocol

/// A `prism` connection waiting for its document to close.
///
/// The event may only follow the reply on the connection, so a waiter holds
/// back an event that arrives before `arm()` (the server calls it once the
/// reply is written) and delivers it then.
public final class Waiter: Sendable {
    private enum State {
        case pending(Event?)
        case armed
        case finished
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .pending(nil))
    private let deliverEvent: @Sendable (Event) -> Void

    public init(deliver: @escaping @Sendable (Event) -> Void) {
        self.deliverEvent = deliver
    }

    /// Called by the router when the document closes.
    func deliver(_ event: Event) {
        let send = state.withLock { state -> Bool in
            switch state {
            case .pending: state = .pending(event); return false
            case .armed: state = .finished; return true
            case .finished: return false
            }
        }
        if send { deliverEvent(event) }
    }

    /// Called by the server after the reply was sent.
    public func arm() {
        let held = state.withLock { state -> Event? in
            guard case .pending(let event) = state else { return nil }
            state = event == nil ? .armed : .finished
            return event
        }
        if let held { deliverEvent(held) }
    }

    /// The connection went away; nothing will be delivered.
    public func cancel() {
        state.withLock { $0 = .finished }
    }

    var isFinished: Bool {
        state.withLock { if case .finished = $0 { true } else { false } }
    }
}

/// Decides which document each request goes to and tells the sink.
///
/// - A plain diff, a whole changeset or a merge opens a new document. A
///   waiting merge learns how it ended: resolved or not.
/// - A partial changeset joins the open changeset with the same group key
///   (the `--UUID`, or the caller's PID and start time), or opens one.
/// - A changeset keyed by a process completes when that process exits (a
///   kqueue process watch); one keyed by a UUID completes when marked
///   closed or after `idleTimeout` without new pairs.
/// - When the user closes a changeset that is still open, its key goes to
///   the closed registry: pairs that arrive later open a new document
///   instead of joining the one that is gone.
///
/// All state lives on a private serial queue; the public methods may be
/// called from any thread.
public final class ChangesetRouter: @unchecked Sendable {
    private final class Document {
        let id: String
        let kind: InvocationKind
        let title: String?
        let groupKey: String?
        var tool: VersionControlTool = .unknown
        var relativePaths: [String] = []
        var isComplete: Bool
        var isClosed = false
        var waiters: [Waiter] = []
        var snapshotFolders: [URL] = []
        var lastAddition = Date()

        init(id: String, kind: InvocationKind, title: String?, groupKey: String?, isComplete: Bool) {
            self.id = id
            self.kind = kind
            self.title = title
            self.groupKey = groupKey
            self.isComplete = isComplete
        }
    }

    private let queue = DispatchQueue(label: "\(PrismInfo.bundleIdentifier).changeset-router")
    private let sink: DocumentSink
    private let snapshots: SnapshotStore?
    private let idleTimeout: TimeInterval
    /// How long the snapshots of a closed document are kept, so that rows
    /// still on their way to its window can be delivered elsewhere.
    private let snapshotGrace: TimeInterval
    private var documents: [String: Document] = [:]
    private var order: [String] = []
    /// Group key -> the changeset still receiving pairs for it.
    private var openChangesets: [String: String] = [:]
    /// Keys of changesets the user closed while they were still open.
    private var closedKeys: Set<String> = []
    private var processWatches: [String: DispatchSourceProcess] = [:]
    private var sweepTimer: DispatchSourceTimer?
    private var nextNumber = 1

    /// - Parameters:
    ///   - sink: receives the documents.
    ///   - snapshots: where temporary files are copied; nil copies nothing.
    ///   - idleTimeout: a UUID changeset without new pairs for this long is
    ///     complete.
    ///   - sweepInterval: how often idle UUID changesets are looked for.
    ///   - snapshotGrace: how long a closed document's snapshots are kept.
    public init(
        sink: DocumentSink,
        snapshots: SnapshotStore?,
        idleTimeout: TimeInterval = 10,
        sweepInterval: TimeInterval = 2,
        snapshotGrace: TimeInterval = 30
    ) {
        self.sink = sink
        self.snapshots = snapshots
        self.idleTimeout = idleTimeout
        self.snapshotGrace = snapshotGrace
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + sweepInterval, repeating: sweepInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.sweepIdleChangesets() }
        timer.resume()
        sweepTimer = timer
    }

    deinit {
        sweepTimer?.cancel()
        processWatches.values.forEach { $0.cancel() }
    }

    // MARK: - Requests

    /// Answers one request. `waiter` is attached to the document when the
    /// invocation asks to wait. Temporary files are copied on the calling
    /// thread, before the router's queue is entered.
    public func handle(_ request: Request, waiter: Waiter? = nil) -> Reply {
        guard request.protocolVersion == IPCProtocol.version else {
            return .failure("prism speaks protocol version \(request.protocolVersion) but \(PrismInfo.appName) "
                            + "speaks version \(IPCProtocol.version); reinstall the command-line tool")
        }
        switch request.operation {
        case .ping:
            return Reply(ok: true)
        case .status:
            return Reply(ok: true, documents: status())
        case .markChangesetClosed:
            guard let uuid = request.changesetUUID else { return .failure("no changeset identifier given") }
            queue.sync { markClosed(key: Invocation.uuidKey(uuid)) }
            return Reply(ok: true)
        case .open:
            guard let invocation = request.invocation else { return .failure("no files given") }
            return open(invocation, waiter: waiter)
        }
    }

    private func open(_ invocation: Invocation, waiter: Waiter?) -> Reply {
        guard !invocation.fileLists.isEmpty, invocation.fileLists.allSatisfy({ !$0.files.isEmpty }) else {
            return .failure("no files given")
        }
        let resolved: [[ComparisonFile]]
        var folder: URL?
        if let snapshots {
            do {
                (resolved, folder) = try snapshots.resolve(invocation.fileLists)
            } catch {
                PrismLog.ipc.error("snapshot failed: \(error.description, privacy: .private)")
                return .failure(error.description)
            }
        } else {
            resolved = invocation.fileLists.map { list in
                list.files.map { ComparisonFile(originalPath: $0.path, path: $0.path, isSnapshot: false) }
            }
        }
        let entries = zip(invocation.fileLists, resolved).map { list, files in
            ChangesetEntry(
                relativePath: list.relativePath ?? files.last(where: { !$0.isPlaceholder })?.fileName ?? "",
                status: list.status,
                files: files
            )
        }
        if invocation.kind == .merge {
            guard let output = invocation.mergeOutput, !output.isEmpty else {
                return .failure("a merge needs an output file")
            }
            guard let files = entries.first?.files, entries.count == 1, (2 ... 3).contains(files.count),
                  !files.contains(where: \.isPlaceholder) else {
                return .failure("a merge needs two files and at most one base")
            }
        }
        let id = queue.sync { route(invocation, entries: entries, snapshotFolder: folder, waiter: waiter) }
        return Reply(ok: true, documentID: id)
    }

    // MARK: - Routing (on queue)

    private func route(
        _ invocation: Invocation,
        entries: [ChangesetEntry],
        snapshotFolder: URL?,
        waiter: Waiter?
    ) -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        let document: Document
        if invocation.kind == .partialChangeset, let key = invocation.groupKey,
           let existingID = openChangesets[key], let existing = documents[existingID],
           !existing.isClosed, !existing.isComplete {
            document = existing
            document.relativePaths += entries.map(\.relativePath)
            sink.append(entries, toDocument: document.id)
        } else {
            let key = invocation.kind == .partialChangeset ? invocation.groupKey : nil
            let title: String? = switch invocation.kind {
            case .diff: invocation.label
            // A merge is named after the file it writes.
            case .merge: invocation.label ?? invocation.mergeOutput.map { ($0 as NSString).lastPathComponent }
            default: invocation.label ?? ChangesetTitle.suggested(for: invocation.caller)
            }
            document = Document(
                id: "doc-\(nextNumber)",
                kind: invocation.kind,
                title: title,
                groupKey: key,
                isComplete: key == nil
            )
            nextNumber += 1
            document.tool = invocation.caller.tool
            document.relativePaths = entries.map(\.relativePath)
            documents[document.id] = document
            order.append(document.id)
            if let key {
                closedKeys.remove(key)
                openChangesets[key] = document.id
            }
            sink.open(DocumentContent(
                id: document.id,
                kind: document.kind,
                title: title,
                tool: invocation.caller.tool,
                entries: entries,
                isComplete: document.isComplete,
                mergeOutput: invocation.kind == .merge ? invocation.mergeOutput : nil
            ))
            if let key, invocation.changesetUUID == nil, let process = invocation.caller.process {
                watch(process, key: key)
            }
        }
        document.lastAddition = Date()
        if let snapshotFolder { document.snapshotFolders.append(snapshotFolder) }
        if invocation.wait, let waiter { document.waiters.append(waiter) }
        return document.id
    }

    /// Completes the changeset of `key` when `process` exits.
    private func watch(_ process: ProcessIdentity, key: String) {
        guard processWatches[key] == nil else { return }
        guard ProcessTable.isRunning(process) else {
            complete(key: key)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.processWatches.removeValue(forKey: key)?.cancel()
            self?.complete(key: key)
        }
        processWatches[key] = source
        source.resume()
        // The process may have exited between the check and the watch.
        if !ProcessTable.isRunning(process) {
            processWatches.removeValue(forKey: key)?.cancel()
            complete(key: key)
        }
    }

    private func complete(key: String) {
        guard let id = openChangesets.removeValue(forKey: key), let document = documents[id],
              !document.isComplete else { return }
        document.isComplete = true
        if !document.isClosed { sink.complete(id) }
    }

    private func markClosed(key: String) {
        complete(key: key)
    }

    private func sweepIdleChangesets() {
        let limit = Date().addingTimeInterval(-idleTimeout)
        for (key, id) in openChangesets where key.hasPrefix("UUID:") {
            if let document = documents[id], document.lastAddition < limit {
                complete(key: key)
            }
        }
        // Forget closed process keys whose process is gone: no late pair
        // can arrive for them any more.
        closedKeys = closedKeys.filter { key in
            guard key.hasPrefix("PID:") else { return true }
            return processWatches[key] != nil
        }
    }

    // MARK: - Closing

    /// The user closed document `id`: wake its waiting `prism` processes
    /// and, if it was still receiving pairs, remember its key so that later
    /// pairs open a new document. Synchronous: once it returns, no new pair
    /// is routed to `id`. Its snapshots are deleted after a grace period.
    public func documentClosed(_ id: String) {
        finish(id, resolved: false)
    }

    /// The user closed merge document `id`: `resolved` when its result was
    /// saved with every conflict resolved. Its waiting `prism` exits 0 when
    /// resolved and 1 otherwise. For any other document this is
    /// `documentClosed(_:)`.
    public func mergeFinished(_ id: String, resolved: Bool) {
        finish(id, resolved: resolved)
    }

    private func finish(_ id: String, resolved: Bool) {
        queue.sync { [self] in
            guard let document = documents[id], !document.isClosed else { return }
            document.isClosed = true
            if let key = document.groupKey, openChangesets[key] == id {
                openChangesets.removeValue(forKey: key)
                closedKeys.insert(key)
            }
            let kind: EventKind = document.kind != .merge ? .documentClosed
                : resolved ? .mergeResolved : .mergeUnresolved
            let event = Event(kind: kind, documentID: id)
            document.waiters.forEach { $0.deliver(event) }
            document.waiters = []
            queue.asyncAfter(deadline: .now() + snapshotGrace) { [weak self] in
                guard let self, let document = self.documents[id], let snapshots = self.snapshots else { return }
                document.snapshotFolders.forEach(snapshots.remove)
                document.snapshotFolders = []
            }
        }
    }

    /// Rows that were routed to document `id` but found its window already
    /// closed: they go to the changeset now open for the same caller, or
    /// to a new document, with their snapshots.
    public func redeliver(_ entries: [ChangesetEntry], fromClosed id: String) {
        guard !entries.isEmpty else { return }
        queue.sync { [self] in
            guard let old = documents[id], old.isClosed else { return }
            let paths = entries.flatMap { $0.files.map(\.path) }
            let moved = old.snapshotFolders.filter { folder in
                let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
                return paths.contains { $0.hasPrefix(prefix) }
            }
            old.snapshotFolders.removeAll { moved.contains($0) }
            old.relativePaths.removeAll { path in entries.contains { $0.relativePath == path } }

            if let key = old.groupKey, let currentID = openChangesets[key], let current = documents[currentID],
               !current.isClosed, !current.isComplete {
                current.relativePaths += entries.map(\.relativePath)
                current.snapshotFolders += moved
                current.lastAddition = Date()
                sink.append(entries, toDocument: currentID)
                return
            }
            let receiving = old.groupKey.map { key in processWatches[key] != nil || key.hasPrefix("UUID:") } ?? false
            let document = Document(id: "doc-\(nextNumber)", kind: old.kind, title: old.title,
                                    groupKey: receiving ? old.groupKey : nil, isComplete: !receiving)
            nextNumber += 1
            document.tool = old.tool
            document.relativePaths = entries.map(\.relativePath)
            document.snapshotFolders = moved
            documents[document.id] = document
            order.append(document.id)
            if receiving, let key = old.groupKey {
                closedKeys.remove(key)
                openChangesets[key] = document.id
            }
            sink.open(DocumentContent(id: document.id, kind: document.kind, title: document.title,
                                      tool: document.tool, entries: entries, isComplete: document.isComplete))
        }
    }

    /// Drops a waiter whose connection ended.
    public func cancel(_ waiter: Waiter) {
        waiter.cancel()
        queue.async { [self] in
            for document in documents.values {
                document.waiters.removeAll { $0 === waiter }
            }
        }
    }

    // MARK: - Inspection

    public func status() -> [DocumentSummary] {
        queue.sync {
            order.compactMap { documents[$0] }.map {
                DocumentSummary(
                    id: $0.id,
                    kind: $0.kind,
                    title: $0.title ?? "",
                    groupKey: $0.groupKey,
                    relativePaths: $0.relativePaths,
                    isComplete: $0.isComplete,
                    isClosed: $0.isClosed
                )
            }
        }
    }

    /// Keys in the closed registry.
    public var closedChangesetKeys: Set<String> { queue.sync { closedKeys } }

    /// Waits until every block queued so far has run (for tests).
    public func drain() { queue.sync {} }

    /// Stops the watches and deletes every snapshot.
    public func shutdown() {
        queue.sync {
            sweepTimer?.cancel()
            sweepTimer = nil
            processWatches.values.forEach { $0.cancel() }
            processWatches = [:]
        }
        snapshots?.removeAll()
    }
}
