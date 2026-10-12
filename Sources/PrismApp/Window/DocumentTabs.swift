// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// What one tab of a document window shows: a text comparison (with or
/// without a changeset sidebar), a folder level, or the empty drop target
/// of a new tab. A later scope (a 3-way merge) plugs in by conforming.
@MainActor
protocol WorkspaceTab: AnyObject {
    var view: NSView { get }
    var title: String { get }
    var symbolName: String { get }
    /// Identifies the pair, so opening it again selects this tab.
    var key: String { get }
    /// Receives menu commands while the tab is selected.
    var actionTarget: NSResponder? { get }
    /// True when closing would lose unsaved changes.
    var hasUnsavedChanges: Bool { get }
    /// The number in the tab's badge.
    var fileCount: Int { get }
    /// The window title while the tab is selected.
    var windowTitle: String { get }
    /// What gets the keyboard when the tab is selected.
    var initialFirstResponder: NSView? { get }
    /// The tab's kind, for context-dependent menus.
    var kind: TabScope { get }
    /// Asks what to do with unsaved changes; `done(true)` lets it close.
    func confirmClose(_ done: @escaping (Bool) -> Void)
    /// Tears the tab down (after `confirmClose`).
    func close()
    /// The tab now lives in `host` (added, or moved from another window).
    func attach(to host: DocumentWindowController)
    /// What is saved to bring the tab back at the next launch; nil when
    /// it cannot come back (a changeset from a finished git run).
    var restorationState: TabState? { get }
}

/// The kinds of content a tab can show.
enum TabScope: String, Sendable {
    case text, folder, merge, empty
}

extension WorkspaceTab {
    var hasUnsavedChanges: Bool { false }
    var fileCount: Int { 2 }
    var windowTitle: String { PrismWindowTitle.default }
    var initialFirstResponder: NSView? { nil }
    func confirmClose(_ done: @escaping (Bool) -> Void) { done(true) }
    func attach(to host: DocumentWindowController) {}
    var restorationState: TabState? { nil }
}

enum PrismWindowTitle {
    /// The title of a document window (the comparison is named by its tab).
    static let `default` = "Prism"
}

/// A text comparison in a tab. It reuses the comparison window's
/// controller and moves its content (path bar, file shelf, Blocks view,
/// bottom bar, and a changeset's sidebar) into the tab, without the
/// controller's own tab strip.
@MainActor
final class TextTab: WorkspaceTab {
    let controller: ComparisonWindowController
    let view: NSView
    let key: String
    /// A fixed title (a file pair opened from a folder level); nil to
    /// follow the comparison's own "a | b".
    private let fixedTitle: String?

    convenience init(a: URL, b: URL, key: String, title: String?, initialChange: Int? = nil) {
        self.init(controller: ComparisonWindowController(a: a, b: b, initialChange: initialChange),
                  key: key, title: title)
    }

    init(controller: ComparisonWindowController, key: String, title: String? = nil) {
        self.controller = controller
        self.key = key
        fixedTitle = title
        let content = controller.window?.contentView ?? NSView()
        (content as? ComparisonContentView)?.tabStrip = nil
        controller.window?.contentView = NSView()
        view = content
        controller.reload()
    }

    var title: String { fixedTitle ?? controller.title }
    var symbolName: String { controller is ChangesetWindowController ? "list.bullet.rectangle" : "doc.text" }
    var actionTarget: NSResponder? { controller }
    var hasUnsavedChanges: Bool { controller.hasUnsavedChanges }
    var fileCount: Int { controller.fileCount }
    var windowTitle: String { controller.window?.title ?? PrismWindowTitle.default }
    /// The text pane with the caret (the Blocks view itself takes no keys).
    var initialFirstResponder: NSView? {
        controller.blocksView.textPane(controller.blocksView.selection?.pane ?? .a)
    }
    var kind: TabScope { .text }
    func confirmClose(_ done: @escaping (Bool) -> Void) { controller.confirmClose(done) }
    func close() { controller.close() }

    func attach(to host: DocumentWindowController) {
        controller.hostWindow = host.window
        controller.onEditedChange = { [weak host] in host?.updateEditedDot() }
        controller.onChromeChange = { [weak host] in host?.refreshStrip() }
        controller.onModeChange = { [weak host] in host?.recordTabs() }
    }

    /// A changeset belongs to a git run that has ended by the next launch.
    var restorationState: TabState? {
        controller is ChangesetWindowController ? nil : .text(TextTabState(controller, title: fixedTitle, key: key))
    }
}

/// A new tab's drop target: files dropped (or chosen) here turn it into a
/// comparison. One file waits for the next.
@MainActor
final class LaunchTab: WorkspaceTab {
    let dropView = LaunchDropView()
    /// Files received so far (fewer than two).
    private(set) var pending: [URL] = []
    /// Two or more files arrived: the window replaces this tab.
    var onFiles: (([URL]) -> Void)?

    init() {
        dropView.onDrop = { [weak self] urls in self?.receive(urls) }
        dropView.onClick = { [weak self] in self?.choose() }
        dropView.setPending([])
    }

    var view: NSView { dropView }
    var initialFirstResponder: NSView? { dropView }
    var title: String { pending.first.map { "\($0.lastPathComponent) | \u{2026}" } ?? "Untitled" }
    var symbolName: String { "square.dashed" }
    var key: String { "empty:\(ObjectIdentifier(self).hashValue)" }
    var actionTarget: NSResponder? { nil }
    var fileCount: Int { pending.count }
    var kind: TabScope { .empty }

    /// Files dropped, chosen, pasted or restored. Two or more make a
    /// comparison; one waits for its partner.
    func receive(_ urls: [URL]) {
        let files = pending + urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if files.count >= 2 {
            pending = []
            dropView.setPending([])
            onFiles?(files)
        } else {
            pending = files
            dropView.setPending(files)
            onFiles?([])
        }
    }

    /// Click on the drop zone: the open panel.
    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = pending.isEmpty ? "Choose two files or two folders to compare."
            : "Choose a file to compare with \u{201C}\(pending[0].lastPathComponent)\u{201D}."
        panel.prompt = "Compare"
        guard panel.runModal() == .OK else { return }
        receive(panel.urls)
    }

    func close() { onFiles = nil }
}

/// The window's content: the tab strip above the selected tab's view.
@MainActor
final class WorkspaceContentView: NSView {
    var tabStrip: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let tabStrip { addSubview(tabStrip) }
            needsLayout = true
        }
    }

    /// Hides the strip (the compact launch window).
    var showsTabStrip = true {
        didSet {
            tabStrip?.isHidden = !showsTabStrip
            needsLayout = true
        }
    }

    var body: NSView? {
        didSet {
            guard body !== oldValue else { return }
            if oldValue?.superview === self { oldValue?.removeFromSuperview() }
            if let body { addSubview(body, positioned: .below, relativeTo: tabStrip) }
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let height = showsTabStrip ? ComparisonContentView.tabStripHeight : 0
        tabStrip?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: ComparisonContentView.tabStripHeight)
        body?.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
    }
}
