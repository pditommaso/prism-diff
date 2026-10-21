// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import CoreServices
import Foundation

/// One displayed level of a comparison: aligned rows plus their counts.
public struct FolderLevel: Sendable, Equatable {
    /// The level's path relative to both roots ("" for the roots).
    public let relativePath: String
    /// Rows in Finder order of their names, unfiltered.
    public let rows: [FolderRow]
    /// Counts over `rows`, for the filter checkboxes.
    public let counts: FolderCounts
    /// True once every directory row has its subtree digest (and every
    /// content check asked for has finished): no spinner remains.
    public let isComplete: Bool
    /// The folder does not exist on that side (drilling into a folder
    /// present on one side only).
    public let leftMissing: Bool
    public let rightMissing: Bool
    /// The folder exists on that side but could not be listed (for example
    /// no permission): its items are unknown, so rows that look one-sided
    /// may not be.
    public let leftUnreadable: Bool
    public let rightUnreadable: Bool
    /// Increases with every update delivered for this level.
    public let generation: Int
}

/// Counters for logs, tests and benches.
public struct FolderStatistics: Sendable, Equatable {
    /// Complete scans of both trees: the first deep pass, and any rescan
    /// after a root was moved or replaced.
    public var fullScans = 0
    /// File-system changes applied by re-listing only the directories that
    /// changed.
    public var incrementalRefreshes = 0
    /// Subtrees scanned again because FSEvents dropped events below them.
    public var subtreeRescans = 0
    /// Directories re-listed by incremental refreshes, in total.
    public var relistedDirectories = 0
    /// Time of the last full deep pass, in milliseconds.
    public var deepPassMs = 0.0
    /// Time of the last incremental refresh, in milliseconds.
    public var lastRefreshMs = 0.0
    /// Directories held in the two retained trees.
    public var directories = 0
    /// Directories that could not be listed during the last deep pass.
    public var unreadableDirectories = 0
    /// Level rows built (and sorted) from listings. Content-check verdicts
    /// reuse a level's rows instead of building them again.
    public var rowBuilds = 0
    /// The listing interface used for each side ("bulk" or "fts").
    public var methods: [String] = []

    public init() {}
}

/// A handle on a level observer; `cancel()` stops the updates.
public final class FolderObservation: Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    public func cancel() { onCancel() }
}

/// Compares two folder trees and keeps the comparison current.
///
/// - The first rows of a level come from a one-level listing of both sides
///   (the shallow pass): files are final at once, directories show as
///   pending.
/// - `start()` runs the deep pass, which walks both trees with a worker
///   pool and keeps one node per directory with the order-independent
///   digest of its subtree; pending rows then resolve.
/// - An FSEvents stream re-lists only the directories that change and
///   applies the digest difference to their ancestors, so updates never
///   need a full rescan.
///
/// All state lives on a private serial queue; observers are called on the
/// queue they name.
public final class FolderSession: @unchecked Sendable {
    public let leftPath: String
    public let rightPath: String
    public let options: FolderOptions

    private let queue = DispatchQueue(label: "io.github.pditommaso.prism.folder-session", qos: .userInitiated)
    /// Content checks: at most 8 at a time, queued rather than parked on
    /// threads. They resolve rows the user is looking at, so they run at
    /// the session's QoS: at utility, GCD gave them no thread at all while
    /// higher-QoS work (another scan, a diff) kept the CPUs busy.
    private let checkQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.pditommaso.prism.folder-content"
        queue.maxConcurrentOperationCount = 8
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let readers: [any DirectoryReader]
    private let log: @Sendable (String) -> Void
    private let cancelled = Flag()

    private enum ScanState { case idle, scanning, ready }
    private var state = ScanState.idle
    private var trees: [DirectoryNode]?
    private var levels: [String: LevelState] = [:]
    private var bufferedEvents: [FolderWatcher.Event] = []
    private var watcher: FolderWatcher?
    private var statistics = FolderStatistics()
    private var readyWaiters: [@Sendable () -> Void] = []
    /// Content-check verdicts by "relative path" + both keys.
    private var contentVerdicts: [ContentKey: Bool] = [:]
    private var contentInFlight: Set<ContentKey> = []
    /// Levels with a compute queued for new verdicts: the verdicts that
    /// arrive meanwhile share it.
    private var verdictComputes: Set<String> = []
    /// Identifies the latest deep pass; results of an older one are dropped.
    private var scanGeneration = 0
    /// FSEvents position when a level was first listed: the stream starts
    /// there, so changes made before `start()` are not missed.
    private var firstListingEventID: FSEventStreamEventId?

    /// - Parameters:
    ///   - left, right: the two folders. Symbolic links in the paths are
    ///     resolved, so FSEvents paths match.
    ///   - log: receives one line per scan and per refresh.
    public init(left: String, right: String, options: FolderOptions = FolderOptions(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        leftPath = Self.canonical(left)
        rightPath = Self.canonical(right)
        self.options = options
        self.log = log
        readers = [leftPath, rightPath].map { DirectoryReaders.reader(for: $0, method: options.method) }
        statistics.methods = readers.map { $0 is FTSReader ? "fts" : "bulk" }
    }

    public convenience init(left: URL, right: URL, options: FolderOptions = FolderOptions(),
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(left: left.path(percentEncoded: false), right: right.path(percentEncoded: false),
                  options: options, log: log)
    }

    deinit {
        watcher?.stop()
    }

    static func canonical(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let resolved = realpath(trimmed, nil) else { return trimmed }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func rootPath(_ side: Side) -> String { side == .left ? leftPath : rightPath }

    // MARK: Lifecycle

    /// Starts the FSEvents stream (unless `watch` is false) and the deep
    /// pass. Calling it again does nothing.
    public func start(watch: Bool = true) {
        queue.async { [self] in
            guard state == .idle, !cancelled.value else { return }
            if watch { startWatcher() }
            beginDeepPass(reason: "initial")
        }
    }

    /// Stops watching and drops every observer. Pending work is abandoned.
    public func stop() {
        cancelled.value = true
        checkQueue.cancelAllOperations()
        queue.async { [self] in
            watcher?.stop()
            watcher = nil
            levels.removeAll()
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0() }
        }
    }

    /// Blocks until the deep pass has finished (or the session stopped).
    /// Returns false on timeout.
    @discardableResult
    public func waitUntilScanned(timeout: TimeInterval = 600) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            if state == .ready || cancelled.value { done.signal() } else { readyWaiters.append { done.signal() } }
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    public var currentStatistics: FolderStatistics { queue.sync { statistics } }

    // MARK: Levels

    /// Observes the level at `relativePath`. The handler runs at once with
    /// the current rows (shallow ones until the deep pass is done), and
    /// again after every change.
    public func observe(_ relativePath: String = "", on handlerQueue: DispatchQueue = .main,
                        _ handler: @escaping @Sendable (FolderLevel) -> Void) -> FolderObservation {
        let id = UUID()
        let path = Self.normalize(relativePath)
        queue.async { [self] in
            guard !cancelled.value else { return }
            let level = levelState(path)
            level.observers[id] = Observer(queue: handlerQueue, handler: handler)
            if let snapshot = level.snapshot {
                handlerQueue.async { handler(snapshot) }
            }
        }
        return FolderObservation { [weak self] in
            guard let self else { return }
            queue.async { [self] in
                guard let level = levels[path] else { return }
                level.observers[id] = nil
                if level.observers.isEmpty { levels[path] = nil }
            }
        }
    }

    /// The current rows of a level, listed now if nobody observes it.
    public func level(_ relativePath: String = "") -> FolderLevel {
        let path = Self.normalize(relativePath)
        return queue.sync {
            if let snapshot = levels[path]?.snapshot { return snapshot }
            let level = LevelState(path: path)
            relist(level, sides: [.left, .right])
            return compute(level, deliver: false)
        }
    }

    /// One-shot comparison: deep pass (and content checks, when enabled)
    /// done before returning. No FSEvents stream is started.
    public static func compare(left: String, right: String, relativePath: String = "",
                               options: FolderOptions = FolderOptions()) -> FolderLevel {
        let session = FolderSession(left: left, right: right, options: options)
        session.start(watch: false)
        session.waitUntilScanned()
        guard options.compareContents else { return session.level(relativePath) }
        let done = DispatchSemaphore(value: 0)
        let observation = session.observe(relativePath, on: DispatchQueue.global()) { level in
            if level.isComplete { done.signal() }
        }
        done.wait()
        observation.cancel()
        return session.level(relativePath)
    }

    static func normalize(_ relativePath: String) -> String {
        relativePath.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private struct Observer {
        let queue: DispatchQueue
        let handler: @Sendable (FolderLevel) -> Void
    }

    private final class LevelState {
        let path: String
        var listings = [LevelLister.Listing(), LevelLister.Listing()] { didSet { baseRows = nil } }
        /// The rows built from the listings, sorted, before content-check
        /// verdicts: sorting is the costly part of a compute, and verdicts
        /// arrive one by one.
        var baseRows: [FolderRow]?
        /// The tree node each side's listing was made against, to notice a
        /// folder that was deleted and created again.
        var nodes: [ObjectIdentifier?] = [nil, nil]
        var observers: [UUID: Observer] = [:]
        var snapshot: FolderLevel?
        var generation = 0

        init(path: String) { self.path = path }
    }

    private func levelState(_ path: String) -> LevelState {
        if let level = levels[path] { return level }
        let level = LevelState(path: path)
        levels[path] = level
        let start = DispatchTime.now().uptimeNanoseconds
        relist(level, sides: [.left, .right])
        _ = compute(level, deliver: false)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        log("folder: level '\(path)' listed in \(format(ms)) ms (\(state == .ready ? "deep" : "shallow"))")
        return level
    }

    private func relist(_ level: LevelState, sides: [Side]) {
        if firstListingEventID == nil { firstListingEventID = FSEventsGetCurrentEventId() }
        for side in sides {
            let tree = trees?[side.rawValue]
            level.listings[side.rawValue] = LevelLister.list(
                rootPath: rootPath(side), relativePath: level.path, reader: readers[side.rawValue],
                includeHidden: options.includeHidden, tree: tree)
            level.nodes[side.rawValue] = tree?.descendant(at: level.path).map(ObjectIdentifier.init)
        }
    }

    /// Builds the rows of a level, applies content verdicts, starts any
    /// content checks still needed, and delivers the result when it
    /// changed.
    @discardableResult
    private func compute(_ level: LevelState, deliver: Bool = true) -> FolderLevel {
        let base: [FolderRow]
        if let rows = level.baseRows {
            base = rows
        } else {
            base = FolderRows.build(left: level.listings[0].entries, right: level.listings[1].entries)
            level.baseRows = base
            statistics.rowBuilds += 1
        }
        var rows = base
        var checking = false
        if options.compareContents && state == .ready {
            for index in rows.indices where rows[index].status == .changed && !rows[index].isPending {
                guard let key = contentKey(level.path, rows[index]) else { continue }
                if let same = contentVerdicts[key] {
                    if same {
                        rows[index].status = .unchanged
                        rows[index].newer = .none
                    }
                } else {
                    rows[index].isPending = true
                    checking = true
                    startContentCheck(key, path: level.path, row: rows[index])
                }
            }
        }
        let complete = state == .ready && !checking && !rows.contains(where: \.isPending)
        let missing = level.listings.map { $0.error == ENOENT || $0.error == ENOTDIR }
        let unreadable = level.listings.map { $0.error != 0 && $0.error != ENOENT && $0.error != ENOTDIR }
        if let old = level.snapshot, old.rows == rows, old.isComplete == complete,
           old.leftMissing == missing[0], old.rightMissing == missing[1],
           old.leftUnreadable == unreadable[0], old.rightUnreadable == unreadable[1] {
            return old
        }
        level.generation += 1
        let snapshot = FolderLevel(relativePath: level.path, rows: rows, counts: FolderCounts(rows),
                                   isComplete: complete, leftMissing: missing[0], rightMissing: missing[1],
                                   leftUnreadable: unreadable[0], rightUnreadable: unreadable[1],
                                   generation: level.generation)
        level.snapshot = snapshot
        if deliver {
            for observer in level.observers.values {
                let handler = observer.handler
                observer.queue.async { handler(snapshot) }
            }
        }
        return snapshot
    }

    // MARK: Deep pass

    private func beginDeepPass(reason: String) {
        state = .scanning
        scanGeneration += 1
        let generation = scanGeneration
        let initial = reason == "initial"
        let roots = [DirectoryNode.root(), DirectoryNode.root()]
        let scanRoots = Side.allCases.map {
            TreeScanner.Root(node: roots[$0.rawValue], path: rootPath($0), reader: readers[$0.rawValue])
        }
        let options = self.options, cancelled = self.cancelled
        log("folder: full scan started (\(reason)): \(leftPath) | \(rightPath), "
            + "\(options.workers) workers, \(statistics.methods.joined(separator: "/"))")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let start = DispatchTime.now().uptimeNanoseconds
            let errors = TreeScanner.scan(scanRoots, includeHidden: options.includeHidden,
                                          workers: options.workers, cancelled: { cancelled.value })
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            queue.async { [self] in
                guard generation == scanGeneration else { return }
                finishDeepPass(roots, errors: errors, ms: ms, initial: initial)
            }
        }
    }

    private func finishDeepPass(_ roots: [DirectoryNode], errors: Int, ms: Double, initial: Bool) {
        guard !cancelled.value else { return }
        trees = roots
        state = .ready
        statistics.fullScans += 1
        statistics.deepPassMs = ms
        statistics.unreadableDirectories = errors
        statistics.directories = roots.reduce(0) { $0 + $1.nodeCount }
        let items = roots.reduce(0) { $0 + $1.totals.count }
        log("folder: full scan done in \(format(ms)) ms: \(items) items, \(statistics.directories) directories"
            + (errors > 0 ? ", \(errors) unreadable" : ""))
        // Every open level is listed again on both sides: files may have
        // changed since the first listing, or a root may have been replaced.
        for level in levels.values {
            relist(level, sides: [.left, .right])
            compute(level)
        }
        if !initial { contentVerdicts.removeAll() }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0() }
        if !bufferedEvents.isEmpty {
            let events = bufferedEvents
            bufferedEvents.removeAll()
            apply(events)
        }
    }

    // MARK: Live refresh

    private func startWatcher() {
        let latency = min(max(options.eventLatency, 0), 1)
        let since = firstListingEventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        watcher = FolderWatcher(paths: [leftPath, rightPath], since: since, latency: latency,
                                queue: queue) { [weak self] events in
            self?.receive(events)
        }
        if watcher == nil { log("folder: FSEvents stream could not be started; no live refresh") }
    }

    /// Runs on `queue` (the stream's dispatch queue).
    private func receive(_ events: [FolderWatcher.Event]) {
        guard !cancelled.value else { return }
        if state != .ready {
            bufferedEvents.append(contentsOf: events)
            return
        }
        apply(events)
    }

    /// Feeds a batch of events as if FSEvents had delivered it (tests).
    func applyForTesting(_ events: [FolderWatcher.Event]) {
        queue.sync { receive(events) }
    }

    /// The event ID the stream starts from (tests).
    var streamStartEventID: FSEventStreamEventId? { queue.sync { firstListingEventID } }

    /// Applies a batch of file-system events.
    private func apply(_ events: [FolderWatcher.Event]) {
        guard let trees else { return }
        // A moved or replaced root, or events dropped at a root, need a full
        // scan; the rest of the batch is kept and applied after it.
        if let index = events.firstIndex(where: { $0.rootChanged || ($0.mustRescanSubtree && isRoot($0.path)) }) {
            let event = events[index]
            log(event.rootChanged ? "folder: a comparison root moved or was replaced; scanning again"
                                  : "folder: events were dropped at a comparison root; scanning again")
            beginDeepPass(reason: event.rootChanged ? "root changed" : "events dropped")
            bufferedEvents.append(contentsOf: events.enumerated().filter {
                $0.offset != index && !$0.element.rootChanged
            }.map(\.element))
            return
        }
        var relists: [Set<String>] = [[], []]
        var rescans: [Set<String>] = [[], []]
        for event in events where !event.historyDone {
            for side in Side.allCases {
                let root = rootPath(side)
                guard event.path == root || event.path.hasPrefix(root == "/" ? "/" : root + "/") else { continue }
                var relative = event.path == root ? "" : String(event.path.dropFirst(root == "/" ? 1 : root.count + 1))
                while relative.hasSuffix("/") { relative.removeLast() }
                if event.mustRescanSubtree {
                    rescans[side.rawValue].insert(relative)
                } else {
                    // A change to an item re-lists the directory holding it.
                    relists[side.rawValue].insert(relative.isEmpty ? "" : Self.parent(of: relative))
                }
            }
        }
        if relists.allSatisfy(\.isEmpty) && rescans.allSatisfy(\.isEmpty) { return }

        let start = DispatchTime.now().uptimeNanoseconds
        var touched: [[(path: String, subtree: Bool)]] = [[], []]
        var relisted = 0, rescanned = 0
        for side in Side.allCases {
            let tree = trees[side.rawValue]
            for path in rescans[side.rawValue] {
                let actual = refresh(tree, side: side, relativePath: path, wholeSubtree: true)
                touched[side.rawValue].append((actual, true))
                rescanned += 1
            }
            for path in relists[side.rawValue].sorted() {
                let actual = refresh(tree, side: side, relativePath: path, wholeSubtree: false)
                touched[side.rawValue].append((actual, false))
                relisted += 1
            }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        statistics.incrementalRefreshes += 1
        statistics.relistedDirectories += relisted
        statistics.subtreeRescans += rescanned
        statistics.lastRefreshMs = ms
        statistics.directories = trees.reduce(0) { $0 + $1.nodeCount }
        let names = Side.allCases.flatMap { side in
            touched[side.rawValue].map { "\(side == .left ? "left" : "right"):'\($0.path)'" }
        }
        log("folder: incremental refresh in \(format(ms)) ms, no full rescan: re-listed \(relisted) "
            + "director\(relisted == 1 ? "y" : "ies")" + (rescanned > 0 ? ", rescanned \(rescanned) subtree(s)" : "")
            + " [\(names.joined(separator: " "))]")

        for level in levels.values {
            var changed = false
            for side in Side.allCases {
                let index = side.rawValue
                let current = trees[index].descendant(at: level.path).map(ObjectIdentifier.init)
                let mustRelist = current != level.nodes[index] || touched[index].contains { item in
                    item.path == level.path || (item.subtree && Self.isInside(level.path, item.path))
                }
                if mustRelist {
                    relist(level, sides: [side])
                    changed = true
                } else if touched[index].contains(where: { Self.isInside($0.path, level.path) }) {
                    LevelLister.refreshDirectories(&level.listings[index].entries, relativePath: level.path, tree: trees[index])
                    changed = true
                }
            }
            if changed { compute(level) }
        }
    }

    /// Re-lists one directory of a side tree (or rescans its subtree) and
    /// applies the change in its subtree totals to every ancestor. A
    /// directory that vanished is handled by refreshing its nearest existing
    /// ancestor. Returns the path actually refreshed.
    private func refresh(_ tree: DirectoryNode, side: Side, relativePath: String, wholeSubtree: Bool) -> String {
        var path = relativePath
        var node = tree.descendant(at: path)
        while node == nil {
            path = Self.parent(of: path)
            node = tree.descendant(at: path)
        }
        guard var target = node else { return path }
        let reader = readers[side.rawValue]
        while true {
            let full = target.isRoot ? rootPath(side) : rootPath(side) + "/" + target.relativePath
            var info = stat()
            let isDirectory = lstat(full, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            if !isDirectory && !target.isRoot, let parent = target.parent {
                target = parent
                continue
            }
            let before = target.totals
            if isDirectory {
                if !target.isRoot { target.mtimeNs = nanoseconds(info.st_mtimespec) }
                if wholeSubtree {
                    let cancelled = self.cancelled
                    TreeScanner.scan([TreeScanner.Root(node: target, path: full, reader: reader)],
                                     includeHidden: options.includeHidden, workers: options.workers,
                                     cancelled: { cancelled.value })
                    for child in target.children { child.parent = target }
                } else {
                    let scan = LevelScanner.scan(target, path: full, reader: reader, includeHidden: options.includeHidden)
                    var merged: [DirectoryNode] = []
                    var fresh: [TreeScanner.Root] = []
                    for candidate in scan.subdirectories {
                        // Reuse a subtree only when it is the same folder: a folder
                        // renamed into this name has another inode.
                        if let existing = target.child(named: candidate.name), existing.readable == candidate.readable,
                           existing.fileID == candidate.fileID {
                            existing.mtimeNs = candidate.mtimeNs
                            merged.append(existing)
                        } else {
                            merged.append(candidate)
                            if candidate.readable {
                                fresh.append(TreeScanner.Root(node: candidate, path: full + "/" + candidate.name,
                                                              reader: reader))
                            }
                        }
                    }
                    if !fresh.isEmpty {
                        let cancelled = self.cancelled
                        TreeScanner.scan(fresh, includeHidden: options.includeHidden, workers: options.workers,
                                         cancelled: { cancelled.value })
                    }
                    target.own = scan.own
                    target.children = merged
                    var totals = target.own
                    for child in merged { totals.add(child.totals) }
                    target.totals = totals
                }
            } else {
                // The root itself is gone: it now holds nothing.
                target.own = SubtreeTotals()
                target.children = []
                target.totals = SubtreeTotals()
            }
            var ancestor = target.parent
            while let current = ancestor {
                current.totals.subtract(before)
                current.totals.add(target.totals)
                ancestor = current.parent
            }
            return target.relativePath
        }
    }

    private func isRoot(_ path: String) -> Bool {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed == leftPath || trimmed == rightPath
    }

    static func parent(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    /// True when `path` is `ancestor` or below it.
    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    // MARK: Content checks

    private struct ContentKey: Hashable {
        let path: String
        let left: UInt64
        let right: UInt64
    }

    private func contentKey(_ levelPath: String, _ row: FolderRow) -> ContentKey? {
        guard let left = row.left, let right = row.right, left.isReadable, right.isReadable else { return nil }
        let bothFiles = (left.kind == .file || left.kind == .other) && left.kind == right.kind && left.size == right.size
        let bothDirectories = left.kind == .directory && right.kind == .directory
        guard bothFiles || bothDirectories else { return nil }
        let path = levelPath.isEmpty ? left.name : levelPath + "/" + left.name
        return ContentKey(path: path, left: left.key, right: right.key)
    }

    private func startContentCheck(_ key: ContentKey, path: String, row: FolderRow) {
        guard !contentInFlight.contains(key), let left = row.left else { return }
        contentInFlight.insert(key)
        let leftFull = leftPath + "/" + key.path, rightFull = rightPath + "/" + key.path
        let isDirectory = left.kind == .directory
        let reader = readers[0], includeHidden = options.includeHidden
        let cancelled = self.cancelled
        checkQueue.addOperation { [self] in
            guard !cancelled.value else { return }
            let isCancelled: @Sendable () -> Bool = { cancelled.value }
            let same = isDirectory
                ? ContentCompare.sameDirectory(leftFull, rightFull, reader: reader, includeHidden: includeHidden,
                                               cancelled: isCancelled)
                : ContentCompare.sameFile(leftFull, rightFull, cancelled: isCancelled)
            guard !cancelled.value else { return }
            queue.async { [self] in
                contentInFlight.remove(key)
                contentVerdicts[key] = same
                guard verdictComputes.insert(path).inserted else { return }
                queue.async { [self] in
                    verdictComputes.remove(path)
                    if let level = levels[path] { compute(level) }
                }
            }
        }
    }

    private func format(_ ms: Double) -> String { String(format: "%.2f", ms) }
}

/// A thread-safe Boolean.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
