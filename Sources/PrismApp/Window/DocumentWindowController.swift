// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import os

/// A document window: one tab per comparison, whatever it compares (text,
/// folders, a changeset, or nothing yet).
///
/// The strip shows equal-width tabs with a scope icon, the "a | b" title,
/// the file-count badge and a close button, plus "+" for a new tab, an
/// overflow menu when the tabs do not fit and a context menu. Tabs can be
/// reordered and dragged out into a window of their own. A window whose
/// only tab is empty is the compact launch window.
///
/// Menu commands go to the selected tab (`supplementalTarget`); undo,
/// the edited dot and closing follow the selected tab or ask every tab.
@MainActor
class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// The size of the launch window.
    static let launchSize = NSSize(width: 400, height: 500)
    /// Posted when tabs change in a way other windows may care about (a
    /// folder comparison swapped in another window).
    static let tabsDidChange = Notification.Name("io.github.pditommaso.prism.tabsDidChange")

    /// Called for every window this class creates by itself (a tab
    /// dragged out), so that the app can track it.
    static var register: ((DocumentWindowController) -> Void)?

    let tabStrip = DocumentTabStrip()
    let content = WorkspaceContentView()
    private(set) var tabs: [WorkspaceTab] = []
    private(set) var selectedIndex = 0
    /// The user chose to close despite unsaved changes in text tabs.
    private var closingConfirmed = false
    /// True while the window is the compact launch window.
    private(set) var isLaunchMode = false

    /// Called when the window has closed.
    var onClose: ((DocumentWindowController) -> Void)?
    /// Asks the app to open a pair in a new window (Command-double-click).
    var onOpenInNewWindow: ((URL, URL) -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ComparisonWindowController.defaultFrameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.contentMinSize = ComparisonWindowController.minimumContentSize
        window.title = PrismWindowTitle.default
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("prism.document")
        window.delegate = self
        // Tab and Shift-Tab follow the controls of the selected tab.
        window.autorecalculatesKeyViewLoop = true
        DisplayOptions.applyMotion(to: window)
        content.tabStrip = tabStrip
        window.contentView = content
        tabStrip.onSelect = { [weak self] index in self?.selectTab(index) }
        tabStrip.onClose = { [weak self] index in self?.requestCloseTab(index) }
        tabStrip.onCloseOthers = { [weak self] index in self?.closeOtherTabs(keeping: index) }
        tabStrip.onAdd = { [weak self] in self?.newTab(nil) }
        tabStrip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabStrip.onDetach = { [weak self] index, point in self?.detachTab(index, at: point) }
        tabStrip.onAddFiles = { [weak self] in self?.openFilesInNewTab(nil) }
        tabStrip.onBadge = { [weak self] index in
            self?.selectTab(index)
            self?.toggleFileShelf(nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(otherTabsChanged(_:)),
                                               name: Self.tabsDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(cascadingFrom previous: NSWindow? = nil) {
        guard let window else { return }
        if let previous {
            window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX,
                                                                              y: previous.frame.maxY)))
        } else {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if let responder = selectedTab?.initialFirstResponder { window.makeFirstResponder(responder) }
    }

    // MARK: tabs

    var selectedTab: WorkspaceTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }

    /// The text tabs (each a text comparison or a changeset).
    var textTabs: [TextTab] { tabs.compactMap { $0 as? TextTab } }

    /// Adds `tab` at `index` (clamped) and selects it.
    func insert(_ tab: WorkspaceTab, at index: Int) {
        let index = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: index)
        tab.attach(to: self)
        if let launch = tab as? LaunchTab {
            launch.onFiles = { [weak self, weak launch] files in
                guard let self, let launch else { return }
                self.launchTab(launch, received: files)
            }
        }
        selectTab(index)
        updateLaunchMode()
    }

    /// Adds a tab after the selected one.
    func append(_ tab: WorkspaceTab) {
        insert(tab, at: tabs.isEmpty ? 0 : selectedIndex + 1)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        let tab = tabs[index]
        content.body = tab.view
        refreshStrip()
        if let responder = tab.initialFirstResponder { window?.makeFirstResponder(responder) }
        record()
    }

    /// Redraws the strip and the window title (a tab's title, badge or
    /// window title changed).
    func refreshStrip() {
        tabStrip.setTabs(tabs.map { DocumentTabStrip.Tab(title: $0.title, symbol: $0.symbolName, count: $0.fileCount) },
                         selected: selectedIndex)
        guard let tab = selectedTab else { return }
        // The title bar always names the app; the comparison is named by its
        // tab, so it is not shown twice. The Window menu lists the comparison.
        if let window {
            window.title = PrismWindowTitle.default
            window.setAccessibilityLabel(tab.title)
            NSApp.changeWindowsItem(window, title: tab.title, filename: false)
        }
    }

    @objc private func otherTabsChanged(_ note: Notification) {
        if note.object as AnyObject? !== self { refreshStrip() }
    }

    /// Tells every window that tab titles may have changed.
    func broadcastTabsChanged() {
        refreshStrip()
        NotificationCenter.default.post(name: Self.tabsDidChange, object: self)
    }

    /// Records the tabs (titles, scopes, layouts) in the perf log.
    func recordTabs() { record() }

    private func record() {
        guard PerfLog.isEnabled else { return }
        let titles = tabs.map(\.title)
        // "folderTabs" is the name the folder checks (M8) look for.
        PerfLog.record("folderTabs", ["titles": titles, "selected": selectedIndex])
        PerfLog.record("windowTabs", [
            "window": window?.windowNumber ?? -1,
            "titles": titles,
            "scopes": tabs.map(\.kind.rawValue),
            "counts": tabs.map(\.fileCount),
            "modes": tabs.map { ($0 as? TextTab)?.controller.blocksView.mode.rawValue ?? "" },
            "selected": selectedIndex,
            "launchMode": isLaunchMode,
        ])
    }

    /// Selects the tab that shows `controller`.
    func select(_ controller: ComparisonWindowController) {
        if let index = tabs.firstIndex(where: { ($0 as? TextTab)?.controller === controller }) { selectTab(index) }
    }

    /// The window's edited dot: any text tab with unsaved changes.
    func updateEditedDot() {
        window?.isDocumentEdited = textTabs.contains { $0.controller.session.isDirty }
    }

    /// Closes tab `index` once it agrees (a text tab with unsaved changes
    /// asks to save them first; a folder tab that is copying asks to stop
    /// the copy).
    func requestCloseTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        let scopes = (tab as? FolderTab).map { [$0.scope] } ?? []
        // A question about a tab is asked with that tab in front.
        if tab.hasUnsavedChanges || scopes.contains(where: \.isCopying) { selectTab(index) }
        tab.confirmClose { [weak self] proceed in
            guard proceed, let self else { return }
            self.confirmStopCopying(scopes, cancelled: { Self.forgetCloseAnswers([tab]) }) { [weak self] in
                guard let self, let current = self.tabs.firstIndex(where: { $0 === tab }) else { return }
                self.closeTab(current)
            }
        }
    }

    /// Closes tab `index` at once (callers have asked it first). The last
    /// tab closes the window.
    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.close()
        updateEditedDot()
        if tabs.isEmpty {
            closingConfirmed = true
            window?.close()
            return
        }
        selectTab(min(index, tabs.count - 1))
        updateLaunchMode()
    }

    /// Closes every tab but `index`, asking each in turn.
    func closeOtherTabs(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        let others = tabs.filter { $0 !== keep }
        func next(_ rest: ArraySlice<WorkspaceTab>) {
            guard let tab = rest.first else {
                if let at = tabs.firstIndex(where: { $0 === keep }) { selectTab(at) }
                return
            }
            guard let current = tabs.firstIndex(where: { $0 === tab }) else { return next(rest.dropFirst()) }
            selectTab(current)
            let scopes = (tab as? FolderTab).map { [$0.scope] } ?? []
            tab.confirmClose { [weak self] proceed in
                guard proceed, let self else { return }
                self.confirmStopCopying(scopes, cancelled: { Self.forgetCloseAnswers([tab]) }) { [weak self] in
                    guard let self, let at = self.tabs.firstIndex(where: { $0 === tab }) else { return }
                    self.closeTab(at)
                    next(rest.dropFirst())
                }
            }
        }
        next(others[...])
    }

    /// Moves a tab within the strip.
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), from != to else { return }
        let selected = selectedTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(to, 0), tabs.count))
        selectedIndex = selected.flatMap { s in tabs.firstIndex { $0 === s } } ?? 0
        selectTab(tabs.firstIndex { $0 === tab } ?? selectedIndex)
    }

    /// Moves tab `index` into a new window (a tab dragged out of the
    /// strip, or Move Tab to New Window). The source keeps the others.
    /// Returns the new window; nil when the tab is the only one.
    @discardableResult
    func detachTab(_ index: Int, at screenPoint: NSPoint? = nil) -> DocumentWindowController? {
        guard tabs.indices.contains(index), tabs.count > 1 else { return nil }
        let tab = tabs.remove(at: index)
        tab.view.removeFromSuperview()
        content.body = nil
        selectTab(min(index, tabs.count - 1))
        updateEditedDot()
        let other = DocumentWindowController()
        other.onOpenInNewWindow = onOpenInNewWindow
        Self.register?(other)
        other.insert(tab, at: 0)
        other.updateEditedDot()
        if let window = other.window, let source = self.window {
            window.setContentSize(source.contentLayoutRect.size)
            if let screenPoint {
                window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 12))
            } else {
                window.setFrameTopLeftPoint(source.cascadeTopLeft(from: NSPoint(x: source.frame.minX,
                                                                                y: source.frame.maxY)))
            }
            other.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            if !NSApp.isActive { window.orderFrontRegardless() }
        }
        PerfLog.record("tabDetached", ["title": tab.title, "remaining": tabs.map(\.title)])
        return other
    }

    // MARK: launch mode

    /// A window whose only tab is empty is the compact launch window
    /// (400×500, not resizable, no strip); the first comparison turns it
    /// into a document window. A new tab in a window already on screen
    /// keeps the window as it is: only a fresh window starts compact.
    private func updateLaunchMode() {
        guard let window else { return }
        let launch = tabs.count == 1 && tabs[0] is LaunchTab
        if launch, !isLaunchMode, !window.isVisible {
            enterLaunchMode()
        } else if !launch, isLaunchMode {
            leaveLaunchMode()
        }
    }

    private func enterLaunchMode() {
        guard let window else { return }
        isLaunchMode = true
        content.showsTabStrip = false
        window.styleMask.remove(.resizable)
        window.contentMinSize = Self.launchSize
        window.setContentSize(Self.launchSize)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        record()
    }

    private func leaveLaunchMode() {
        guard let window else { return }
        isLaunchMode = false
        content.showsTabStrip = true
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.styleMask.insert(.resizable)
        window.contentMinSize = ComparisonWindowController.minimumContentSize
        window.standardWindowButton(.zoomButton)?.isHidden = false
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: ComparisonWindowController.defaultFrameSize))
        frame.origin = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        if let visible = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
        record()
    }

    /// A launch tab got its files: the comparison replaces it.
    private func launchTab(_ launch: LaunchTab, received files: [URL]) {
        guard let index = tabs.firstIndex(where: { $0 === launch }) else { return }
        guard !files.isEmpty else {
            refreshStrip()
            return
        }
        let made = Self.makeTabs(for: files)
        guard !made.isEmpty else { return NSSound.beep() }
        tabs.remove(at: index)
        launch.close()
        for (offset, tab) in made.enumerated() {
            tabs.insert(tab, at: index + offset)
            tab.attach(to: self)
        }
        updateLaunchMode()
        selectTab(index)
    }

    /// Tabs for files that were opened or dropped together: two folders
    /// make a folder comparison; two or more files one text comparison
    /// (more than two go on its file shelf). Folders mixed with files
    /// cannot be compared.
    static func makeTabs(for urls: [URL]) -> [WorkspaceTab] {
        let directories = urls.map(AppDelegate.isDirectory)
        if directories.allSatisfy({ $0 }) {
            var made: [WorkspaceTab] = []
            var index = 0
            while index + 1 < urls.count {
                let document = FolderDocument(left: urls[index], right: urls[index + 1])
                made.append(document.makeTab(relativePath: ""))
                RecentComparisons.shared.note([urls[index], urls[index + 1]])
                index += 2
            }
            return made
        }
        guard !directories.contains(true), urls.count >= 2 else { return [] }
        let controller = ComparisonWindowController(a: urls[0], b: urls[1])
        if urls.count > 2 { controller.setShelfFiles(urls.map { ShelfEntry(url: $0) }, a: 0, b: 1) }
        RecentComparisons.shared.note(Array(urls.prefix(2)))
        return [TextTab(controller: controller, key: "text:\(UUID().uuidString)")]
    }

    // MARK: menu commands

    /// File > New Tab (and the strip's "+"): an empty tab to drop files on.
    @objc func newTab(_ sender: Any?) {
        append(LaunchTab())
    }

    /// The tab context menu's Open Files in New Tab: choose files, then a
    /// new tab compares them.
    @objc func openFilesInNewTab(_ sender: Any?) {
        let launch = LaunchTab()
        append(launch)
        launch.choose()
        if tabs.contains(where: { $0 === launch }), launch.pending.isEmpty, tabs.count > 1,
           let index = tabs.firstIndex(where: { $0 === launch }) {
            closeTab(index)
        }
    }

    /// File > Close Comparison (Command-W): the selected tab; the last one
    /// closes the window.
    @objc func closeComparison(_ sender: Any?) {
        if tabs.count <= 1 {
            window?.performClose(sender)
        } else {
            requestCloseTab(selectedIndex)
        }
    }

    @objc func selectNextTab(_ sender: Any?) { selectTab((selectedIndex + 1) % max(tabs.count, 1)) }
    @objc func selectPreviousTab(_ sender: Any?) { selectTab((selectedIndex + tabs.count - 1) % max(tabs.count, 1)) }

    /// Moves the selected tab to a new window.
    @objc func moveTabToNewWindow(_ sender: Any?) { detachTab(selectedIndex) }

    /// View > Toggle File Shelf: the selected tab's shelf.
    @objc func toggleFileShelf(_ sender: Any?) {
        switch selectedTab {
        case let text as TextTab: text.controller.toggleFileShelf(sender)
        case let folder as FolderTab: folder.scope.toggleFileShelf(sender)
        default: NSSound.beep()
        }
    }

    /// Edit > Select Next A & B / Previous A & B: the text comparison's
    /// shelf, or (two folders) swapping the roots.
    @objc func selectNextAAndB(_ sender: Any?) { stepBoth(sender, forward: true) }
    @objc func selectPreviousAAndB(_ sender: Any?) { stepBoth(sender, forward: false) }

    private func stepBoth(_ sender: Any?, forward: Bool) {
        switch selectedTab {
        case let text as TextTab:
            forward ? text.controller.selectNextAAndB(sender) : text.controller.selectPreviousAAndB(sender)
        case let folder as FolderTab:
            folder.document.swapSides()
        default:
            NSSound.beep()
        }
    }

    /// Edit > Paste to Comparison: the clipboard's text becomes a file of
    /// the selected comparison (an empty tab's first or second file, or
    /// another file on a text comparison's shelf).
    @objc func pasteToComparison(_ sender: Any?) {
        guard let url = ClipboardSnippets.writeClipboard() else { return NSSound.beep() }
        switch selectedTab {
        case let launch as LaunchTab: launch.receive([url])
        case let text as TextTab: text.controller.addShelfFiles([ShelfEntry(url: url, display: .nameOnly)], makeB: true)
        default:
            // A folder comparison cannot take text: the snippet starts a
            // new tab and waits there for a second file.
            let launch = LaunchTab()
            append(launch)
            launch.receive([url])
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)), #selector(moveTabToNewWindow(_:)):
            return tabs.count > 1
        case #selector(toggleFileShelf(_:)):
            switch selectedTab {
            case let text as TextTab: return text.controller.validateMenuItem(menuItem)
            case is FolderTab: return true
            default: return false
            }
        case #selector(selectNextAAndB(_:)), #selector(selectPreviousAAndB(_:)):
            switch selectedTab {
            case let text as TextTab: return text.controller.validateMenuItem(menuItem)
            case let folder as FolderTab: return !folder.scope.isCopying
            default: return false
            }
        case #selector(pasteToComparison(_:)):
            guard ClipboardSnippets.hasText else { return false }
            switch selectedTab {
            case is LaunchTab: return true
            case let text as TextTab: return !(text.controller is ChangesetWindowController)
            default: return true
            }
        default:
            return true
        }
    }

    /// Menu commands go to the selected tab's controller.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let target = selectedTab?.actionTarget, target.responds(to: action) { return target }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: copying

    var folderScopes: [FolderScopeController] { tabs.compactMap { ($0 as? FolderTab)?.scope } }

    /// True while any folder tab of this window copies files.
    var isCopying: Bool { folderScopes.contains(where: \.isCopying) }

    /// Cancels every copy of this window, then runs `body`.
    func stopCopying(then body: @escaping () -> Void) {
        let copying = folderScopes.filter(\.isCopying)
        guard !copying.isEmpty else { return body() }
        var remaining = copying.count
        for scope in copying {
            scope.stopCopying {
                remaining -= 1
                if remaining == 0 { body() }
            }
        }
    }

    /// Asks before closing tabs that are copying; "Stop Copying" cancels
    /// the copies and closes once they have stopped.
    private func confirmStopCopying(_ scopes: [FolderScopeController], cancelled: (() -> Void)? = nil,
                                    then body: @escaping () -> Void) {
        guard scopes.contains(where: \.isCopying), let window else { return body() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Prism is still copying files."
        alert.informativeText = "If you close this comparison now, the item being copied is discarded and the remaining items are not copied."
        alert.addButton(withTitle: "Continue Copying")
        alert.addButton(withTitle: "Stop Copying")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else {
                cancelled?()
                return
            }
            var remaining = scopes.count
            for scope in scopes {
                scope.stopCopying {
                    remaining -= 1
                    if remaining == 0 { body() }
                }
            }
        }
    }

    // MARK: window

    /// The whole window closes only after every tab with unsaved changes
    /// has been asked, one at a time, and copies have been stopped.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingConfirmed { return true }
        guard isCopying || tabs.contains(where: \.hasUnsavedChanges) else { return true }
        confirmWindowClose()
        return false
    }

    /// Asks about each tab with unsaved changes, then about the copies
    /// still running, and only then stops them and closes the window.
    /// Cancelling any question keeps everything as it was, earlier "Don't
    /// Save" answers included.
    private func confirmWindowClose() {
        confirmTabs(tabs.filter(\.hasUnsavedChanges)[...], answered: []) { [weak self] in
            guard let self else { return }
            let asked = self.tabs.filter(\.hasUnsavedChanges)
            self.confirmStopCopying(self.folderScopes, cancelled: { Self.forgetCloseAnswers(asked) }) { [weak self] in
                guard let self else { return }
                self.closingConfirmed = true
                self.window?.close()
            }
        }
    }

    private func confirmTabs(_ remaining: ArraySlice<WorkspaceTab>, answered: [WorkspaceTab],
                             then body: @escaping () -> Void) {
        guard let tab = remaining.first else { return body() }
        if let index = tabs.firstIndex(where: { $0 === tab }) { selectTab(index) }
        tab.confirmClose { [weak self] proceed in
            guard proceed else {
                Self.forgetCloseAnswers(answered + [tab])
                return
            }
            self?.confirmTabs(remaining.dropFirst(), answered: answered + [tab], then: body)
        }
    }

    /// A cancelled close: the "Don't Save" answers given on the way no
    /// longer hold.
    static func forgetCloseAnswers(_ tabs: [WorkspaceTab]) {
        for case let text as TextTab in tabs { text.controller.closingConfirmed = false }
    }

    /// Undo and Redo act on the selected tab: a text tab's edits, or a
    /// folder tab's staging (none while that tab copies, so Undo and Redo
    /// are disabled).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        switch selectedTab {
        case let text as TextTab: text.controller.session.undoManager
        case let folder as FolderTab: folder.scope.isCopying ? nil : folder.scope.stagingUndo
        default: nil
        }
    }

    /// View > Open Selection answers to Return while a folder tab is in
    /// front of the key window.
    func windowDidBecomeKey(_ notification: Notification) { Self.bindReturn(true) }
    func windowDidResignKey(_ notification: Notification) { Self.bindReturn(false) }

    static func bindReturn(_ bound: Bool) {
        guard let item = openSelectionItem(in: NSApp.mainMenu) else { return }
        item.keyEquivalent = bound ? "\r" : ""
        item.keyEquivalentModifierMask = []
    }

    private static func openSelectionItem(in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == #selector(FolderScopeController.openSelection(_:)) { return item }
            if let found = openSelectionItem(in: item.submenu) { return found }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        Self.bindReturn(false)
        for tab in tabs { tab.close() }
        tabs.removeAll()
        content.body = nil
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }

    // MARK: restoration

    /// What brings this window back at the next launch; nil when none of
    /// its tabs can come back.
    var restorationState: WindowState? {
        let states = tabs.compactMap(\.restorationState)
        guard !states.isEmpty, let window else { return nil }
        let selected = selectedTab?.restorationState == nil ? 0
            : tabs[..<selectedIndex].filter { $0.restorationState != nil }.count
        return WindowState(frame: WindowState.Frame(window.frame), tabs: states, selected: selected)
    }
}
