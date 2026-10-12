// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismIntegration
import PrismProtocol

/// Connects the `prism` socket server to the app's windows: plain diffs
/// open comparison windows, changesets open changeset windows, and closing
/// a window tells the router (which wakes any `prism --wait`).
@MainActor
final class AppIPCService {
    let router: ChangesetRouter
    let server: IPCServer
    private let sink: MainThreadSink
    /// Opens a comparison window for two files.
    private let openComparison: (URL, URL) -> ComparisonWindowController
    /// Opens two folders in a folder comparison window.
    private let openFolders: ((URL, URL) -> DocumentWindowController)?
    /// Shows a comparison built here (a changeset) in a window.
    private let host: (ComparisonWindowController) -> Void
    /// Open documents by router document ID.
    private(set) var windows: [String: ComparisonWindowController] = [:]
    private var changesets: [ChangesetWindowController] = []
    /// Open three-way merges by router document ID.
    private(set) var merges: [String: MergeWindowController] = [:]

    /// - Parameter securesDirectory: force the socket's folder to 0700
    ///   (the default location; not an overridden path).
    init(socketPath: String, securesDirectory: Bool,
         openComparison: @escaping (URL, URL) -> ComparisonWindowController,
         openFolders: ((URL, URL) -> DocumentWindowController)? = nil,
         host: @escaping (ComparisonWindowController) -> Void) {
        SnapshotStore.removeStale()
        sink = MainThreadSink()
        router = ChangesetRouter(sink: sink, snapshots: .temporary())
        server = IPCServer(socketPath: socketPath, router: router, securesDirectory: securesDirectory)
        self.openComparison = openComparison
        self.openFolders = openFolders
        self.host = host
        sink.service = self
    }

    func start() throws(IPCServer.StartError) {
        try server.start()
        PerfLog.record("ipcListening", ["socket": server.socketPath])
    }

    /// Tells the router how every open merge ends, before the app quits: a
    /// merge saved resolved reports resolved, any other unresolved. The
    /// events are written to the waiting prism before this returns, so
    /// `stop()` afterwards cannot cut them off.
    func finishMerges() {
        for controller in merges.values { controller.finishNow() }
    }

    /// Stops listening and deletes the snapshots (at quit).
    func stop() {
        server.stop()
        router.shutdown()
    }

    nonisolated static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: sink callbacks (main thread)

    func open(_ document: DocumentContent) {
        if document.kind == .merge {
            openMerge(document)
            return
        }
        let controller: ComparisonWindowController
        switch document.kind {
        case .merge:
            return
        case .diff:
            let sent = document.entries.first?.files ?? []
            let files = sent.map { URL(filePath: $0.path) }
            let a = files.first ?? URL(filePath: IPCProtocol.placeholderPath)
            let b = files.count > 1 ? files[1] : URL(filePath: IPCProtocol.placeholderPath)
            // Two folders open a folder comparison; closing it ends --wait.
            if files.count == 2, let openFolders, Self.isFolder(a), Self.isFolder(b) {
                let folders = openFolders(a, b)
                let previous = folders.onClose
                folders.onClose = { [weak self] closed in
                    previous?(closed)
                    self?.router.documentClosed(document.id)
                }
                return
            }
            controller = openComparison(a, b)
            controller.session.snapshotSides = Self.snapshotSides(sent, at: 0)
            if let label = document.title { controller.window?.title = label }
            // More than two files go on the comparison's file shelf.
            if files.count > 2 {
                let entries = zip(files, sent).map { ShelfEntry(url: $0, isSnapshot: $1.isSnapshot) }
                controller.setShelfFiles(entries, a: 0, b: 1)
            }
            controller.onChromeChange?()
        case .partialChangeset, .changeset:
            let changeset = ChangesetWindowController(document: document)
            changeset.onClose = { [weak self] closed in
                self?.changesets.removeAll { $0 === closed }
            }
            changesets.append(changeset)
            host(changeset)
            controller = changeset
        }
        windows[document.id] = controller
        let previous = controller.onClose
        controller.onClose = { [weak self] closed in
            previous?(closed)
            self?.windows.removeValue(forKey: document.id)
            self?.router.documentClosed(document.id)
        }
        // A new document from prism brings the app forward (the user just
        // asked for it from Terminal or git); rows added to an open
        // changeset do not.
        // Tests (PRISM_TESTING=1) never take the focus from the user.
        AppFocus.activate()
        Self.show(controller.presentingWindow)
    }

    /// A three-way merge: A, B and the base (when given) from the one entry,
    /// the result saved to the document's output. Closing the window tells
    /// the router whether the merge was resolved.
    private func openMerge(_ document: DocumentContent) {
        let sent = document.entries.first?.files ?? []
        guard sent.count >= 2, let output = document.mergeOutput else {
            router.mergeFinished(document.id, resolved: false)
            return
        }
        let files = MergeFiles(a: URL(filePath: sent[0].path), b: URL(filePath: sent[1].path),
                               base: sent.count > 2 ? URL(filePath: sent[2].path) : nil,
                               output: URL(filePath: output))
        let controller = MergeWindowController(files: files, title: document.title)
        // Show the names git gave the versions, not those of the private copies.
        controller.header.setNames(a: sent[0].fileName, b: sent[1].fileName)
        merges[document.id] = controller
        controller.onFinish = { [weak self] resolved in
            self?.router.mergeFinished(document.id, resolved: resolved)
        }
        controller.onClose = { [weak self] _ in
            self?.merges.removeValue(forKey: document.id)
        }
        controller.present(cascadingFrom: NSApp.keyWindow)
        AppFocus.activate()
        Self.show(controller.window)
    }

    /// The sides of the pair starting at `index` that are prism snapshots.
    static func snapshotSides(_ files: [ComparisonFile], at index: Int) -> Set<DiffSide> {
        var sides: Set<DiffSide> = []
        if files.indices.contains(index), files[index].isSnapshot { sides.insert(.a) }
        if files.indices.contains(index + 1), files[index + 1].isSnapshot { sides.insert(.b) }
        return sides
    }

        /// Puts a window from prism on screen whether or not the app is
    /// active. For an inactive app (launched in the background by prism,
    /// or under PRISM_TESTING), makeKeyAndOrderFront leaves the window
    /// behind the other applications' windows, where AppKit may hold back
    /// its drawing; orderFrontRegardless shows it on top without
    /// activating the app or taking the keyboard focus.
    static func show(_ window: NSWindow?) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            window.orderFrontRegardless()
        }
    }

    nonisolated static var isTesting: Bool {
        ProcessInfo.processInfo.environment[IPCEnvironment.testingVariable] == "1"
    }

    fileprivate func append(_ entries: [ChangesetEntry], to id: String) {
        if let changeset = windows[id] as? ChangesetWindowController {
            changeset.append(entries)
        } else {
            // The window closed while these rows were on their way.
            router.redeliver(entries, fromClosed: id)
        }
    }

    fileprivate func complete(_ id: String) {
        (windows[id] as? ChangesetWindowController)?.markComplete()
    }
}

/// Receives documents on the router's queue and hands them to the main
/// thread, in order.
private final class MainThreadSink: DocumentSink, @unchecked Sendable {
    /// Set once on the main thread before the server starts.
    @MainActor weak var service: AppIPCService?

    func open(_ document: DocumentContent) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { service?.open(document) } }
    }

    func append(_ entries: [ChangesetEntry], toDocument id: String) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { service?.append(entries, to: id) } }
    }

    func complete(_ id: String) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { service?.complete(id) } }
    }
}
