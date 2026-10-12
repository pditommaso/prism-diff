// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismIntegration
import PrismProtocol

/// A changeset window: the files sent by one `git difftool` run (or one
/// `prism --changeset`) in a sidebar, with the selected file's comparison
/// on the right. Files may keep arriving while the caller runs.
@MainActor
final class ChangesetWindowController: ComparisonWindowController {
    let documentID: String
    let changesetTitle: String
    let sidebarView: ChangesetSidebarView
    private(set) var entries: [ChangesetEntry]
    private(set) var isComplete: Bool

    init(document: DocumentContent) {
        documentID = document.id
        changesetTitle = document.title ?? "Changes"
        entries = document.entries
        isComplete = document.isComplete
        sidebarView = ChangesetSidebarView(tool: document.tool)
        let first = document.entries.first
        let urls = Self.urls(of: first)
        super.init(a: urls.a, b: urls.b)
        pathDisplay = Self.display(of: first)
        session.snapshotSides = Self.snapshotSides(of: first)
        window?.title = changesetTitle
        window?.identifier = NSUserInterfaceItemIdentifier("prism.changeset")
        sidebar = sidebarView
        sidebarView.onSelect = { [weak self] index in self?.showEntry(index) }
        sidebarView.setEntries(entries)
        sidebarView.setReceiving(!isComplete)
        if let first = sidebarView.rows.entryOrder.first {
            sidebarView.selectEntry(first)
        }
        updateChrome()
        record("changesetOpened")
    }

    override var title: String { changesetTitle }
    override var fileCount: Int { entries.count }

    /// More files from the same caller.
    func append(_ more: [ChangesetEntry]) {
        entries += more
        sidebarView.setEntries(entries)
        updateChrome()
        record("changesetUpdated")
    }

    /// No more files will arrive.
    func markComplete() {
        isComplete = true
        sidebarView.setReceiving(false)
        record("changesetCompleted")
    }

    private func showEntry(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        let urls = Self.urls(of: entry)
        if urls.a == urlA, urls.b == urlB { return }
        // Showing another file drops the current one's unsaved edits: ask
        // first, and stay on the current file when cancelled.
        if hasUnsavedChanges {
            confirmClose { [weak self] proceed in
                guard let self else { return }
                if proceed {
                    self.closingConfirmed = false
                    self.showEntry(index)
                } else if let current = self.entries.firstIndex(where: {
                    let shown = Self.urls(of: $0)
                    return shown.a == self.urlA && shown.b == self.urlB
                }) {
                    self.sidebarView.selectEntry(current)
                }
            }
            return
        }
        showFiles(a: urls.a, b: urls.b, display: Self.display(of: entry), snapshots: Self.snapshotSides(of: entry))
        PerfLog.record("changesetSelection", ["id": documentID, "entry": index, "relativePath": entry.relativePath])
    }

    static func urls(of entry: ChangesetEntry?) -> (a: URL, b: URL) {
        let files = entry?.files ?? []
        let a = files.first.map { URL(filePath: $0.path) } ?? URL(filePath: IPCProtocol.placeholderPath)
        let b = files.dropFirst().first.map { URL(filePath: $0.path) } ?? URL(filePath: IPCProtocol.placeholderPath)
        return (a, b)
    }

    /// Snapshots show only their name; a missing side says so.
    static func display(of entry: ChangesetEntry?) -> (a: PathBarView.Display, b: PathBarView.Display) {
        func display(_ file: ComparisonFile?) -> PathBarView.Display {
            guard let file else { return .absent }
            if file.isPlaceholder { return .absent }
            return file.isSnapshot ? .nameOnly : .path
        }
        let files = entry?.files ?? []
        return (display(files.first), display(files.dropFirst().first))
    }

    /// Sides that are prism snapshots (private copies): merging or typing
    /// into them is refused.
    static func snapshotSides(of entry: ChangesetEntry?) -> Set<DiffSide> {
        let files = entry?.files ?? []
        var sides: Set<DiffSide> = []
        if files.first?.isSnapshot == true { sides.insert(.a) }
        if files.dropFirst().first?.isSnapshot == true { sides.insert(.b) }
        return sides
    }

    // MARK: file navigation (Shift-Cmd-Up / Shift-Cmd-Down)

    @objc func selectNextFile(_ sender: Any?) {
        if !sidebarView.moveSelection(by: 1) { NSSound.beep() }
    }

    @objc func selectPreviousFile(_ sender: Any?) {
        if !sidebarView.moveSelection(by: -1) { NSSound.beep() }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectNextFile(_:)), #selector(selectPreviousFile(_:)):
            return entries.count > 1
        // A changeset lists its files in the sidebar: no shelf.
        case #selector(toggleFileShelf(_:)), #selector(selectNextAAndB(_:)), #selector(selectPreviousAAndB(_:)),
             #selector(selectNextB(_:)), #selector(selectPreviousB(_:)), #selector(selectNextA(_:)),
             #selector(selectPreviousA(_:)), #selector(paste(_:)), #selector(pasteToComparison(_:)):
            return false
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    private func record(_ event: String) {
        guard PerfLog.isEnabled else { return }
        PerfLog.record(event, [
            "id": documentID,
            "title": changesetTitle,
            "rows": entries.count,
            "sidebarRows": sidebarView.rows.entryOrder.count,
            "complete": isComplete,
            "windowNumber": presentingWindow?.windowNumber ?? -1,
            "wallMs": PerfLog.rounded(Date().timeIntervalSince1970 * 1000),
        ])
    }
}
