// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import FolderCore
import os
import PrismProtocol

/// The folder window of M8 is now a document window whose first tab shows
/// the two roots. The name stays for the code and tests that open one.
typealias FolderWindowController = DocumentWindowController

/// Two root folders compared in one or more tabs. The first tab shows the
/// roots; opening a folder row adds a tab for that level next to its
/// parent, a file pair a text tab. Every folder tab of the pair shares one
/// `FolderSession`, so drilling down never rescans, wherever the tabs are
/// (a tab dragged into another window keeps its session).
@MainActor
final class FolderDocument {
    private(set) var leftRoot: URL
    private(set) var rightRoot: URL
    private(set) var session: FolderSession
    /// The folder levels open on this pair, in any window.
    private let scopes = NSHashTable<FolderScopeController>.weakObjects()
    private var openTabs = 0
    private var started = false
    /// The Folders settings observer (removed with the last tab).
    nonisolated(unsafe) private var settingsObserver: (any NSObjectProtocol)?

    init(left: URL, right: URL) {
        leftRoot = left
        rightRoot = right
        session = Self.makeSession(left: left, right: right)
        settingsObserver = NotificationCenter.default.addObserver(forName: FolderSettings.didChange, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    deinit {
        // Runs on the main thread (the document is released there); the
        // token is only read here and in stopObservingSettings().
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    private func stopObservingSettings() {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
    }

    private static func makeSession(left: URL, right: URL) -> FolderSession {
        FolderSession(left: left, right: right, options: FolderSettings().options) { line in
            PrismLog.folder.info("\(line, privacy: .public)")
            Task { @MainActor in PerfLog.record("folderLog", ["line": line]) }
        }
    }

    /// Root folder names for titles; their parents' names when equal.
    var rootNames: (String, String) {
        let a = leftRoot.lastPathComponent, b = rightRoot.lastPathComponent
        if a != b { return (a, b) }
        return (leftRoot.deletingLastPathComponent().lastPathComponent,
                rightRoot.deletingLastPathComponent().lastPathComponent)
    }

    /// A tab for the level at `relativePath` ("" for the roots).
    func makeTab(relativePath: String) -> FolderTab {
        let scope = FolderScopeController(session: session, relativePath: relativePath)
        scopes.add(scope)
        retitle(scope)
        openTabs += 1
        // The first level observes the session before it starts scanning.
        if !started {
            started = true
            session.start()
        }
        return FolderTab(document: self, scope: scope)
    }

    private func retitle(_ scope: FolderScopeController) {
        let relativePath = scope.relativePath
        let name = (relativePath as NSString).lastPathComponent
        let names = relativePath.isEmpty ? (leftRoot.lastPathComponent, rightRoot.lastPathComponent) : (name, name)
        scope.title = DocumentWindowController.title(relativePath: relativePath, leftName: names.0,
                                                     rightName: names.1, roots: rootNames)
    }

    var isCopying: Bool { scopes.allObjects.contains(where: \.isCopying) }

    /// Swaps A and B: a new session over the swapped roots for every
    /// folder tab of the pair.
    func swapSides() {
        guard !isCopying else { return NSSound.beep() }
        swap(&leftRoot, &rightRoot)
        rebuildSession()
    }

    /// Compares another folder on one side (a path bar sibling): the root
    /// that, with the level's relative path, gives `levelURL`.
    func replaceRoot(_ side: Side, level relativePath: String, with levelURL: URL) {
        guard !isCopying else { return NSSound.beep() }
        var root = levelURL
        for _ in relativePath.split(separator: "/") { root = root.deletingLastPathComponent() }
        if side == .left { leftRoot = root } else { rightRoot = root }
        rebuildSession()
    }

    private func rebuildSession() {
        session.stop()
        session = Self.makeSession(left: leftRoot, right: rightRoot)
        for scope in scopes.allObjects {
            scope.attach(session)
            retitle(scope)
        }
        session.start()
        NotificationCenter.default.post(name: DocumentWindowController.tabsDidChange, object: nil)
    }

    private func settingsChanged() {
        if session.options != FolderSettings().options { rebuildSession() }
    }

    /// A tab of the pair closed; the last one stops the session.
    fileprivate func tabClosed() {
        openTabs -= 1
        if openTabs <= 0 {
            session.stop()
            stopObservingSettings()
        }
    }
}

@MainActor
final class FolderTab: WorkspaceTab {
    let document: FolderDocument
    let scope: FolderScopeController

    init(document: FolderDocument, scope: FolderScopeController) {
        self.document = document
        self.scope = scope
    }

    var view: NSView { scope.view }
    var title: String { scope.title }
    var symbolName: String { "folder.fill" }
    var key: String { "folder:" + scope.relativePath }
    var actionTarget: NSResponder? { scope }
    var initialFirstResponder: NSView? { scope.view.tableA }
    var kind: TabScope { .folder }

    func attach(to host: DocumentWindowController) {
        scope.onOpen = { [weak host] scope, row, newWindow in host?.open(row, from: scope, newWindow: newWindow) }
        scope.onSwap = { [weak self] in self?.document.swapSides() }
        scope.onChooseRoot = { [weak self] side, url in
            guard let self else { return }
            self.document.replaceRoot(side, level: self.scope.relativePath, with: url)
        }
    }

    func close() {
        scope.cancelCopying(nil)
        scope.detach()
        document.tabClosed()
    }

    var restorationState: TabState? {
        .folder(FolderTabState(left: document.leftRoot.path(percentEncoded: false),
                               right: document.rightRoot.path(percentEncoded: false),
                               relativePath: scope.relativePath))
    }
}

extension DocumentWindowController {
    /// A window comparing two folders: one tab with the roots.
    convenience init(left: URL, right: URL) {
        self.init()
        let document = FolderDocument(left: left, right: right)
        insert(document.makeTab(relativePath: ""), at: 0)
    }

    /// "left | right" for the roots; "src (left) | src (right)" below them,
    /// where both sides have the same name.
    static func title(relativePath: String, leftName: String, rightName: String, roots: (String, String)) -> String {
        if relativePath.isEmpty { return "\(leftName) | \(rightName)" }
        if leftName == rightName { return "\(leftName) (\(roots.0)) | \(rightName) (\(roots.1))" }
        return "\(leftName) | \(rightName)"
    }

    /// Opens a row of `scope`: a folder level in a new tab, a file pair in
    /// a text tab, or (with Command) either in a new window. A tab already
    /// showing the same pair is selected instead.
    func open(_ row: FolderRow, from scope: FolderScopeController, newWindow: Bool) {
        guard let document = tabs.lazy.compactMap({ $0 as? FolderTab }).first(where: { $0.scope === scope })?.document
        else { return }
        let session = document.session
        let path = scope.relativePath.isEmpty ? row.name : scope.relativePath + "/" + row.name
        let leftURL = URL(filePath: session.leftPath + "/" + path)
        let rightURL = URL(filePath: session.rightPath + "/" + path)
        let isFolder = row.isFolderPair
        let isFilePair = row.left != nil && row.right != nil && !(row.left!.isDirectory || row.right!.isDirectory)
        guard isFolder || isFilePair else {
            NSSound.beep()
            return
        }
        if newWindow {
            onOpenInNewWindow?(leftURL, rightURL)
            return
        }
        let key = (isFolder ? "folder:" : "text:") + path
        if let existing = tabs.firstIndex(where: { $0.key == key }) {
            selectTab(existing)
            return
        }
        let parent = tabs.firstIndex { ($0 as? FolderTab)?.scope === scope } ?? selectedIndex
        if isFolder {
            insert(document.makeTab(relativePath: path), at: parent + 1)
        } else {
            let title = Self.title(relativePath: path, leftName: row.name, rightName: row.name, roots: document.rootNames)
            addTextTab(a: leftURL, b: rightURL, key: key, title: title, at: parent + 1)
        }
    }

    /// Opens a text tab for a file pair at `index`: its sheets, edited dot
    /// and undo belong to this window.
    @discardableResult
    func addTextTab(a: URL, b: URL, key: String, title: String?, at index: Int) -> TextTab {
        let tab = TextTab(a: a, b: b, key: key, title: title)
        insert(tab, at: index)
        return tab
    }

    /// Swaps A and B of the selected folder tab's pair.
    func swapSides() {
        (selectedTab as? FolderTab)?.document.swapSides()
    }
}
