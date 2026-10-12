// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import FolderCore

/// One folder level shown in a tab: the A and B tables with a centre
/// gutter, aligned row for row, and a bottom bar with the filters.
@MainActor
final class FolderScopeController: NSResponder, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    /// Path of this level relative to both roots ("" for the roots).
    let relativePath: String
    let view = FolderScopeView()
    private(set) var session: FolderSession
    private var observation: FolderObservation?
    private(set) var level: FolderLevel?
    /// The rows on screen: sorted, then filtered.
    private(set) var displayed: [FolderRow] = []
    private(set) var sort = FolderSort.byName
    private(set) var filter = FolderFilter.all
    private var syncingSelection = false
    private var syncingScroll = false
    private var stallMonitor: MainThreadStallMonitor?
    private var opened = DispatchTime.now().uptimeNanoseconds
    private var reportedComplete = false
    private var iconCache: [String: NSImage] = [:]

    // MARK: staging and copy state

    /// The staged copy directions of this level.
    private(set) var staging: FolderStaging
    /// Undo and redo of staging choices (the window asks for it while this
    /// tab is selected).
    let stagingUndo = UndoManager()
    /// The copy in progress, if any.
    private(set) var runner: FolderCopyRunner?
    /// Where replaced items go.
    var trash: any TrashMover = FolderTrash.current()
    /// Clone files where the volume allows it (tests turn it off).
    var allowClone = true
    /// Answers copy errors without an alert (tests).
    var errorResolver: ((CopyFailure) -> CopyRecovery)?
    /// Called after every copy, with how it ended.
    var onCopyFinished: ((CopyOutcome) -> Void)?
    /// The last copy's outcome (tests and logs).
    private(set) var lastOutcome: CopyOutcome?
    private var waitingForCopyEnd: [() -> Void] = []
    private(set) var appBundleWarningShown = false
    /// Answers the app-bundle warning without an alert (tests).
    var appBundleConfirmer: ((@escaping (Bool) -> Void) -> Void)?
    /// Leftovers of interrupted copies are cleaned once per tab.
    private var cleanedStale = false
    private var summarySheet: CopySummarySheet?
    /// The error sheet while the copy waits for an answer.
    private var errorAlert: NSAlert?
    /// The number of staged choices from which the window shows as edited.
    static let editedThreshold = 5

    var isCopying: Bool { runner != nil }

    /// Opens a row: the folder pair in a new tab, a file pair in a text tab.
    /// `newWindow` when Command is held.
    var onOpen: ((FolderScopeController, FolderRow, _ newWindow: Bool) -> Void)?
    /// Swap A and B (handled by the window, which owns the session).
    var onSwap: (() -> Void)?
    /// The tab title, for logs.
    var title = ""
    /// A sibling folder chosen in the path bar: compare it on that side.
    var onChooseRoot: ((Side, URL) -> Void)?
    /// The file shelf (the two folders of this level), when shown.
    private(set) lazy var shelfView: FileShelfView = {
        let shelf = FileShelfView()
        shelf.addButton.isEnabled = false
        shelf.onAdd = { NSSound.beep() }
        return shelf
    }()

    init(session: FolderSession, relativePath: String) {
        self.session = session
        self.relativePath = relativePath
        staging = FolderStaging(levelPath: relativePath)
        super.init()
        let bar = view.bottomBar
        bar.copyRightButton.target = self
        bar.copyRightButton.action = #selector(copyToRight(_:))
        bar.copyLeftButton.target = self
        bar.copyLeftButton.action = #selector(copyToLeft(_:))
        bar.copyButton.target = self
        bar.copyButton.action = #selector(startCopyingFiles(_:))
        bar.setCopyState(staged: 0, copying: nil, cancelling: false)
        view.pathBar.swapButton.target = self
        view.pathBar.swapButton.action = #selector(swapSides(_:))
        view.pathBar.onChoose = { [weak self] side, url in
            guard AppDelegate.isDirectory(url) else { return NSSound.beep() }
            self?.onChooseRoot?(side == .a ? .left : .right, url)
        }
        for table in view.tables {
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.doubleAction = #selector(tableDoubleClicked(_:))
            table.onReturn = { [weak self] in self?.openSelection(nil) }
        }
        for button in view.bottomBar.filterButtons {
            button.target = self
            button.action = #selector(filterChanged(_:))
        }
        for clip in view.scrollViews.map(\.contentView) {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
        updatePaths()
        attach(session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Observes this level of `session` (again, after a rescan or a swap).
    func attach(_ session: FolderSession) {
        observation?.cancel()
        // A new session (after a swap) turns directions around: start over.
        if session !== self.session {
            staging.resetAll()
            stagingUndo.removeAllActions()
            stagingChanged()
        }
        self.session = session
        updatePaths()
        opened = DispatchTime.now().uptimeNanoseconds
        reportedComplete = false
        if PerfLog.isEnabled {
            stallMonitor?.stop()
            let monitor = MainThreadStallMonitor()
            monitor.start()
            stallMonitor = monitor
        }
        observation = session.observe(relativePath, on: .main) { [weak self] level in
            MainActor.assumeIsolated { self?.show(level) }
        }
    }

    func detach() {
        observation?.cancel()
        observation = nil
        stallMonitor?.stop()
        stallMonitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    func url(_ side: Side) -> URL {
        let root = session.rootPath(side)
        return URL(filePath: relativePath.isEmpty ? root : root + "/" + relativePath, directoryHint: .isDirectory)
    }

    private func updatePaths() {
        view.pathBar.setURLs(a: url(.left), b: url(.right))
        if view.shelf != nil { shelfView.show(shelfModel) }
    }

    private var shelfModel: ShelfModel {
        ShelfModel(files: [ShelfEntry(url: url(.left)), ShelfEntry(url: url(.right))])
    }

    /// View > Toggle File Shelf: the two folders of this level.
    @objc func toggleFileShelf(_ sender: Any?) {
        view.shelf = view.shelf == nil ? shelfView : nil
        shelfView.show(shelfModel)
    }

    // MARK: rows

    private func show(_ level: FolderLevel) {
        let selected = selectedNames()
        self.level = level
        if staging.reconcile(with: level.rows) { updateCopyBar() }
        if !cleanedStale {
            cleanedStale = true
            cleanStaleTemporaries()
        }
        rebuild(keeping: selected)
        report(level)
    }

    fileprivate func rebuild(keeping selected: Set<String>) {
        guard let level else { return }
        displayed = FolderRows.filtered(FolderRows.sorted(level.rows, by: sort), filter)
        view.bottomBar.setCounts(level.counts)
        syncingSelection = true
        for table in view.tables { table.reloadData() }
        let rows = IndexSet(displayed.indices.filter { selected.contains(key(displayed[$0])) })
        for table in view.sideTables { table.selectRowIndexes(rows, byExtendingSelection: false) }
        syncingSelection = false
    }

    private func key(_ row: FolderRow) -> String {
        (row.left == nil ? "-" : "L") + (row.right == nil ? "-" : "R") + row.name
    }

    fileprivate func selectedNames() -> Set<String> {
        Set(view.tableA.selectedRowIndexes.compactMap { $0 < displayed.count ? key(displayed[$0]) : nil })
    }

    var selectedRows: [FolderRow] {
        view.tableA.selectedRowIndexes.compactMap { $0 < displayed.count ? displayed[$0] : nil }
    }

    /// Selects the first displayed row with this name (used by tests).
    func select(name: String) {
        guard let index = displayed.firstIndex(where: { $0.name == name }) else { return }
        view.tableA.selectRowIndexes([index], byExtendingSelection: false)
        view.tableA.scrollRowToVisible(index)
    }

    private func report(_ level: FolderLevel) {
        guard PerfLog.isEnabled else { return }
        var fields = describe()
        fields["complete"] = level.isComplete
        fields["generation"] = level.generation
        fields["sinceOpenMs"] = PerfLog.rounded(Double(DispatchTime.now().uptimeNanoseconds - opened) / 1e6)
        fields["sinceProcessStartMs"] = PerfLog.rounded(PerfLog.millisecondsSinceProcessStart())
        if level.isComplete && !reportedComplete {
            reportedComplete = true
            if let monitor = stallMonitor {
                monitor.stop()
                fields["longestMainThreadGapMs"] = PerfLog.rounded(monitor.longestGapMilliseconds)
                stallMonitor = nil
            }
            fields["rssMB"] = PerfLog.rounded(PerfLog.residentMegabytes())
        }
        PerfLog.record("folderLevel", fields)
    }

    /// What the tables show, for the perf log and tests.
    func describe() -> [String: Any] {
        let counts = level?.counts ?? FolderCounts()
        return [
            "path": relativePath,
            "title": title,
            "changed": counts.changed, "unchanged": counts.unchanged, "unmatched": counts.unmatched,
            "filterLabels": view.bottomBar.filterButtons.map(\.title),
            "visibleRows": displayed.count,
            "staged": staging.ordered.map { "\($0.relativePath) \($0.direction.rawValue)\($0.replaces ? " replace" : "")" },
            "copyStatus": view.bottomBar.copyStatus.stringValue,
            "copyButton": view.bottomBar.copyButton.title,
            "copying": isCopying,
            "unreadable": [level?.leftUnreadable == true, level?.rightUnreadable == true],
            "rows": displayed.map { row in
                "\(row.left?.name ?? "") | \(row.right?.name ?? "") | \(row.status.rawValue)"
                    + (row.right.map { " | \($0.modificationTimeNs)" } ?? "")
            },
            "wallMs": (Date().timeIntervalSince1970 * 1000).rounded(),
        ]
    }

    // MARK: table data

    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FolderRowView()
        guard row < displayed.count else { return view }
        let item = displayed[row]
        if let side = self.view.side(of: tableView) {
            view.status = item.entry(side) == nil ? nil : item.status
            view.staged = item.entry(side) != nil && staging.direction(of: item)?.source == side
        } else {
            view.status = nil
            view.isGutter = true
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayed.count, let column = tableColumn else { return nil }
        let item = displayed[row]
        guard let side = view.side(of: tableView) else {
            let cell = tableView.makeView(withIdentifier: FolderScopeView.gutterCell, owner: nil) as? GutterCell ?? GutterCell()
            cell.isPending = item.isPending
            let button = cell.stageButton
            button.status = item.status
            button.allowed = item.allowedDirections
            button.direction = staging.direction(of: item)
            button.setAccessibilityIdentifier("prism.folder.stage.\(item.name)")
            button.setAccessibilityLabel("Copy direction for \(item.name)")
            let identity = item.identity
            button.onPress = { [weak self] in self?.cycleStaging(identity: identity) }
            return cell
        }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? FolderCell
            ?? FolderCell(identifier: column.identifier, withIcon: column.identifier == FolderScopeView.nameColumn)
        guard let entry = item.entry(side) else {
            // The folder on this side could not be listed: say so instead
            // of a blank alignment cell.
            let unreadable = side == .left ? level?.leftUnreadable == true : level?.rightUnreadable == true
            cell.set(text: unreadable && column.identifier == FolderScopeView.nameColumn ? "Folder not readable" : "",
                     icon: nil)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
        cell.textField?.textColor = .labelColor
        switch column.identifier {
        case FolderScopeView.nameColumn:
            cell.set(text: entry.name, icon: icon(for: entry, side: side))
        case FolderScopeView.dateColumn:
            cell.set(text: FolderFormat.date(entry.modificationDate), icon: nil)
        default:
            cell.set(text: entry.isDirectory && !entry.isDeep ? "\u{2013}" : FolderFormat.size(entry.size), icon: nil)
        }
        cell.selectedOnColour = item.status != .unchanged
        return cell
    }

    private func icon(for entry: FolderEntry, side: Side) -> NSImage {
        let path = url(side).path(percentEncoded: false) + "/" + entry.name
        if let cached = iconCache[path] { return cached }
        let image: NSImage
        switch entry.kind {
        case .directory: image = NSWorkspace.shared.icon(for: .folder)
        default: image = NSWorkspace.shared.icon(forFile: path)
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache[path] = image
        return image
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier == FolderScopeView.nameColumn, row < displayed.count else { return nil }
        return displayed[row].name
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView !== view.gutter
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let source = notification.object as? NSTableView, source !== view.gutter else { return }
        syncingSelection = true
        for table in view.sideTables where table !== source {
            table.selectRowIndexes(source.selectedRowIndexes, byExtendingSelection: false)
        }
        syncingSelection = false
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let side = view.side(of: tableView),
              let key = FolderSortKey(rawValue: descriptor.key ?? "") else { return }
        sort = FolderSort(key: key, side: side, ascending: descriptor.ascending)
        for table in view.sideTables where table !== tableView {
            table.sortDescriptors = tableView.sortDescriptors
        }
        rebuild(keeping: selectedNames())
    }

    @objc private func scrolled(_ note: Notification) {
        guard !syncingScroll, let clip = note.object as? NSClipView else { return }
        syncingScroll = true
        let y = clip.bounds.origin.y
        for scroll in view.scrollViews where scroll.contentView !== clip {
            if scroll.contentView.bounds.origin.y != y {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        syncingScroll = false
    }

    // MARK: actions

    @objc func tableDoubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0, sender.clickedRow < displayed.count else { return }
        let newWindow = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        onOpen?(self, displayed[sender.clickedRow], newWindow)
    }

    /// View ▸ Open Selection (Return): opens every selected row.
    @objc func openSelection(_ sender: Any?) {
        let rows = selectedRows
        if rows.isEmpty { NSSound.beep() }
        for row in rows { onOpen?(self, row, false) }
    }

    @objc func filterChanged(_ sender: NSButton) {
        filter = view.bottomBar.filter
        rebuild(keeping: selectedNames())
        if PerfLog.isEnabled {
            var fields = describe()
            fields["filter"] = filter.rawValue
            PerfLog.record("folderFilter", fields)
        }
    }

    /// Sets the filter checkboxes (used by tests).
    func setFilter(_ filter: FolderFilter) {
        view.bottomBar.filter = filter
        filterChanged(view.bottomBar.changedButton)
    }

    @objc func selectNextChange(_ sender: Any?) { stepChange(forward: true) }
    @objc func selectPreviousChange(_ sender: Any?) { stepChange(forward: false) }

    private func stepChange(forward: Bool) {
        let current = view.tableA.selectedRow
        let indices = forward ? Array((current + 1)..<displayed.count) : Array((0..<max(current, 0)).reversed())
        guard let next = indices.first(where: { displayed[$0].status != .unchanged }) else {
            NSSound.beep()
            return
        }
        view.tableA.selectRowIndexes([next], byExtendingSelection: false)
        view.tableA.scrollRowToVisible(next)
    }

    @objc func swapSides(_ sender: Any?) { onSwap?() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSelection(_:)): return !selectedRows.isEmpty
        case #selector(selectNextChange(_:)), #selector(selectPreviousChange(_:)):
            return displayed.contains { $0.status != .unchanged }
        case #selector(copyToRight(_:)):
            return !isCopying && selectedRows.contains { $0.allowedDirections.contains(.toRight) }
        case #selector(copyToLeft(_:)):
            return !isCopying && selectedRows.contains { $0.allowedDirections.contains(.toLeft) }
        case #selector(resetSelection(_:)):
            // With nothing staged it does nothing, but stays available.
            return !isCopying
        case #selector(startCopyingFiles(_:)):
            let title = isCopying ? "Cancel Copying Files" : "Start Copying Files"
            if menuItem.title != title { menuItem.title = title }
            return isCopying ? !(runner?.isCancelling ?? true) : !staging.isEmpty
        default: return true
        }
    }
}

// MARK: - Staging and copying

extension FolderScopeController {
    /// Merge > Copy to Right: stages every selected row that can copy right.
    @objc func copyToRight(_ sender: Any?) { stage(selectedRows, .toRight) }

    /// Merge > Copy to Left.
    @objc func copyToLeft(_ sender: Any?) { stage(selectedRows, .toLeft) }

    /// Merge > Reset Selection: clears the choices of the selected rows, or
    /// every choice when no selected row has one.
    @objc func resetSelection(_ sender: Any?) {
        guard !isCopying else { return NSSound.beep() }
        var next = staging
        if !next.reset(selectedRows) { next.resetAll() }
        apply(next, action: "Reset Copy Selection")
    }

    /// Stages `direction` on the rows that allow it; beeps when none does.
    func stage(_ rows: [FolderRow], _ direction: CopyDirection) {
        guard !isCopying else { return NSSound.beep() }
        var next = staging
        guard next.stage(rows, direction) else {
            if !rows.contains(where: { $0.allowedDirections.contains(direction) }) { NSSound.beep() }
            return
        }
        confirmAppBundle { [weak self] in
            self?.apply(next, action: direction == .toRight ? "Copy to Right" : "Copy to Left")
        }
    }

    /// The gutter button of a row: none, then each allowed direction.
    func cycleStaging(identity: String) {
        guard !isCopying, let row = level?.rows.first(where: { $0.identity == identity }) else { return }
        var next = staging
        next.cycle(row)
        let adds = next.direction(of: row) != nil
        if adds {
            confirmAppBundle { [weak self] in self?.apply(next, action: "Change Copy Direction") }
        } else {
            apply(next, action: "Change Copy Direction")
        }
    }

    /// Replaces the choices, registering the previous ones for undo.
    private func apply(_ next: FolderStaging, action: String) {
        // The window offers no Undo or Redo while copying; this guards any
        // other way in.
        guard next != staging, !isCopying else { return }
        let previous = staging
        stagingUndo.registerUndo(withTarget: self) { scope in
            MainActor.assumeIsolated { scope.apply(previous, action: action) }
        }
        stagingUndo.setActionName(action)
        staging = next
        if let level { staging.reconcile(with: level.rows) }
        stagingChanged()
    }

    fileprivate func stagingChanged() {
        rebuild(keeping: selectedNames())
        updateCopyBar()
        view.window?.isDocumentEdited = staging.count >= Self.editedThreshold
        if PerfLog.isEnabled { PerfLog.record("folderStaging", describe()) }
    }

    fileprivate func updateCopyBar() {
        view.bottomBar.setCopyState(staged: staging.count, copying: runner?.progress,
                                    cancelling: runner?.isCancelling ?? false)
    }

    // MARK: app bundles

    /// True when this level is inside an application bundle on either side.
    var isInsideAppBundle: Bool {
        Side.allCases.contains { side in
            url(side).pathComponents.contains { ($0 as NSString).pathExtension.lowercased() == "app" }
        }
    }

    /// Runs `body`, after a warning the first time a copy is staged inside
    /// an application bundle (unless the warning was turned off).
    private func confirmAppBundle(_ body: @escaping () -> Void) {
        let settings = FolderSettings()
        guard isInsideAppBundle, !appBundleWarningShown, settings.warnOnAppBundles else { return body() }
        // Asked again after Cancel; only Continue silences it for this tab.
        let answer: (Bool) -> Void = { [weak self] proceed in
            guard proceed else { return }
            self?.appBundleWarningShown = true
            body()
        }
        if let appBundleConfirmer { return appBundleConfirmer(answer) }
        guard let window = view.window else { return body() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This comparison is inside an application bundle."
        alert.informativeText = "Changing files inside an app can break it or stop it from opening. Continue only if you know what the copy does."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don\u{2019}t warn me again"
        alert.beginSheetModal(for: window) { response in
            if alert.suppressionButton?.state == .on { settings.warnOnAppBundles = false }
            answer(response == .alertFirstButtonReturn)
        }
    }

    // MARK: copying

    /// Merge > Start Copying Files (Command-Return), or the Copy button.
    /// During a copy the same command cancels it.
    @objc func startCopyingFiles(_ sender: Any?) {
        if isCopying {
            cancelCopying(sender)
            return
        }
        guard !staging.isEmpty else { return NSSound.beep() }
        let skipSummary = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        guard FolderSettings().showCopySummary, !skipSummary, let window = view.window else {
            beginCopy()
            return
        }
        let names = (url(.left).lastPathComponent, url(.right).lastPathComponent)
        let names2 = names.0 == names.1
            ? (url(.left).deletingLastPathComponent().lastPathComponent + "/" + names.0,
               url(.right).deletingLastPathComponent().lastPathComponent + "/" + names.1)
            : names
        let sheet = CopySummarySheet(items: staging.ordered, leftName: names2.0, rightName: names2.1)
        summarySheet = sheet
        sheet.present(on: window) { [weak self] confirmed in
            self?.summarySheet = nil
            if confirmed { self?.beginCopy() }
        }
        if PerfLog.isEnabled {
            PerfLog.record("folderCopySummary", ["rows": staging.ordered.map { "\($0.name) | \(CopySummarySheet.phrase($0))" }])
        }
    }

    /// Removes what interrupted copies left at this level on both sides
    /// (hidden `.prism-copy-` items), off the main thread.
    func cleanStaleTemporaries(minimumAge: TimeInterval = 300, then done: (@Sendable ([String]) -> Void)? = nil) {
        let paths = Side.allCases.map { url($0).path(percentEncoded: false) }
        let trash = self.trash
        DispatchQueue.global(qos: .utility).async {
            let handled = paths.flatMap { FolderCopier.cleanStaleTemporaries(in: $0, trash: trash, minimumAge: minimumAge) }
            done?(handled)
        }
    }

    /// The summary sheet while it is up (tests and the acceptance run).
    var presentedSummary: CopySummarySheet? { summarySheet }

    @objc func cancelCopying(_ sender: Any?) {
        guard let runner, !runner.isCancelling else { return }
        runner.cancel()
        // An error sheet waiting for an answer is answered "stop".
        if let alert = errorAlert, let window = alert.window.sheetParent {
            window.endSheet(alert.window, returnCode: .abort)
        }
        updateCopyBar()
    }

    /// Starts copying the staged items, without the summary.
    func beginCopy() {
        guard !isCopying, !staging.isEmpty else { return }
        let copier = FolderCopier(leftRoot: session.leftPath, rightRoot: session.rightPath, items: staging.ordered,
                                  trash: trash, allowClone: allowClone)
        let lease: CopyLock.Lease
        switch CopyLock.shared.acquire(copier.lockPaths) {
        case .success(let held): lease = held
        case .failure(let conflict):
            showBusy(conflict.path)
            return
        }
        let runner = FolderCopyRunner(copier: copier, lease: lease)
        self.runner = runner
        runner.onProgress = { [weak self] _ in self?.updateCopyBar() }
        runner.onError = { [weak self] failure, reply in
            guard let self else { return reply(.stop) }
            self.resolve(failure, reply: reply)
        }
        runner.onFinish = { [weak self] outcome in self?.finishCopy(outcome) }
        if PerfLog.isEnabled {
            PerfLog.record("folderCopy", ["phase": "started", "items": copier.items.map(\.relativePath)])
        }
        rebuild(keeping: selectedNames())
        updateCopyBar()
        runner.start()
    }

    private func showBusy(_ path: String) {
        let alert = NSAlert()
        alert.messageText = "\u{201C}\((path as NSString).lastPathComponent)\u{201D} is part of another copy in progress."
        alert.informativeText = "Wait until that copy finishes, then try again."
        if let window = view.window { alert.beginSheetModal(for: window) } else { NSSound.beep() }
        if PerfLog.isEnabled { PerfLog.record("folderCopy", ["phase": "busy", "path": path]) }
    }

    /// Asks what to do about a failed item: Try Again, Skip or Stop.
    private func resolve(_ failure: CopyFailure, reply: @escaping (CopyRecovery) -> Void) {
        if PerfLog.isEnabled {
            PerfLog.record("folderCopyError", ["path": failure.relativePath, "code": failure.code,
                                               "title": failure.title, "reason": failure.reason])
        }
        if let errorResolver {
            reply(errorResolver(failure))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.reason + " Skip it to go on with the other items, or stop copying."
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop Copying")
        alert.addButton(withTitle: "Try Again")
        alert.window.setAccessibilityIdentifier("prism.copyError")
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: reply(.skip)
            case .alertThirdButtonReturn: reply(.retry)
            default: reply(.stop)
            }
        }
        if let window = view.window {
            errorAlert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.errorAlert = nil
                answer(response)
            }
        } else {
            answer(alert.runModal())
        }
    }

    private func finishCopy(_ outcome: CopyOutcome) {
        runner = nil
        lastOutcome = outcome
        // Copied items leave the staging; skipped and remaining ones stay.
        var next = staging
        let done = Set(outcome.copied)
        for copy in next.ordered where done.contains(copy.relativePath) {
            if let row = level?.rows.first(where: { $0.identity == copy.rowIdentity }) { next.set(row, nil) }
        }
        staging = next
        // Copies cannot be undone, and older staging steps no longer apply.
        stagingUndo.removeAllActions()
        stagingChanged()
        if PerfLog.isEnabled {
            PerfLog.record("folderCopy", ["phase": "finished", "copied": outcome.copied, "skipped": outcome.skipped,
                                          "notAttempted": outcome.notAttempted, "cancelled": outcome.cancelled,
                                          "stopped": outcome.stopped, "trashed": outcome.trashed])
        }
        onCopyFinished?(outcome)
        let waiting = waitingForCopyEnd
        waitingForCopyEnd.removeAll()
        waiting.forEach { $0() }
    }

    /// Cancels the copy (if any) and runs `body` once it has stopped.
    func stopCopying(then body: @escaping () -> Void) {
        guard isCopying else {
            body()
            return
        }
        waitingForCopyEnd.append(body)
        cancelCopying(nil)
    }
}

// MARK: - Views

/// Path bar, the three tables and the bottom bar, top to bottom.
@MainActor
final class FolderScopeView: NSView {
    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let dateColumn = NSUserInterfaceItemIdentifier("date")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let gutterCell = NSUserInterfaceItemIdentifier("gutter")
    static let gutterWidth: CGFloat = 54
    static let rowHeight: CGFloat = 22

    let pathBar = PathBarView(target: nil, swapAction: #selector(FolderScopeController.swapSides(_:)))
    let tableA = FolderTableView()
    let tableB = FolderTableView()
    let gutter = FolderTableView()
    let bottomBar = FolderBottomBar()
    let scrollViews: [NSScrollView]
    /// The file shelf below the path bar, when shown.
    var shelf: NSView? {
        didSet {
            guard shelf !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let shelf { addSubview(shelf) }
            needsLayout = true
        }
    }

    var tables: [FolderTableView] { [tableA, gutter, tableB] }
    var sideTables: [FolderTableView] { [tableA, tableB] }

    override init(frame: NSRect) {
        scrollViews = (0..<3).map { _ in NSScrollView() }
        super.init(frame: frame)
        for (index, table) in [tableA, gutter, tableB].enumerated() {
            let scroll = scrollViews[index]
            configure(table, gutter: index == 1)
            scroll.documentView = table
            scroll.hasVerticalScroller = index == 2
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = true
            scroll.automaticallyAdjustsContentInsets = false
            addSubview(scroll)
        }
        tableA.setAccessibilityIdentifier("prism.folder.tableA")
        tableB.setAccessibilityIdentifier("prism.folder.tableB")
        gutter.setAccessibilityIdentifier("prism.folder.gutter")
        tableA.setAccessibilityLabel("Folder A")
        tableB.setAccessibilityLabel("Folder B")
        gutter.setAccessibilityLabel("Copy directions")
        addSubview(pathBar)
        addSubview(bottomBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func side(of table: NSTableView) -> Side? {
        table === tableA ? .left : (table === tableB ? .right : nil)
    }

    private func configure(_ table: FolderTableView, gutter isGutter: Bool) {
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.backgroundColor = .textBackgroundColor
        table.focusRingType = .none
        if isGutter {
            let column = NSTableColumn(identifier: Self.gutterCell)
            column.title = ""
            column.width = Self.gutterWidth
            column.resizingMask = []
            table.addTableColumn(column)
            table.selectionHighlightStyle = .none
            table.refusesFirstResponder = true
            return
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (identifier, title, width) in [(Self.nameColumn, "Name", 300.0), (Self.dateColumn, "Date Modified", 200.0),
                                           (Self.sizeColumn, "Size", 90.0)] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier == Self.nameColumn ? "name"
                                                                : identifier == Self.dateColumn ? "date" : "size",
                                                              ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.highlightedTableColumn = nil
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let pathHeight = ComparisonContentView.pathBarHeight
        let top = pathHeight + (shelf == nil ? 0 : FileShelfView.height)
        let bottom = bounds.height - ComparisonContentView.bottomBarHeight
        pathBar.frame = NSRect(x: 0, y: 0, width: width, height: pathHeight)
        shelf?.frame = NSRect(x: 0, y: pathHeight, width: width, height: FileShelfView.height)
        let side = floor((width - Self.gutterWidth) / 2)
        scrollViews[0].frame = NSRect(x: 0, y: top, width: side, height: max(bottom - top, 0))
        scrollViews[1].frame = NSRect(x: side, y: top, width: Self.gutterWidth, height: max(bottom - top, 0))
        scrollViews[2].frame = NSRect(x: side + Self.gutterWidth, y: top, width: width - side - Self.gutterWidth,
                                      height: max(bottom - top, 0))
        bottomBar.frame = NSRect(x: 0, y: bottom, width: width, height: ComparisonContentView.bottomBarHeight)
        pathBar.splitX = side + Self.gutterWidth / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A table that opens its selection on Return or Enter.
@MainActor
final class FolderTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A row tinted by its status. Absent entries (alignment rows) stay blank;
/// the selection takes the status's strong colour.
@MainActor
final class FolderRowView: NSTableRowView {
    var status: RowStatus?
    var isGutter = false
    /// The row is staged and this side is the copy's source: drawn in the
    /// status's strong colour.
    var staged = false

    override func drawBackground(in dirtyRect: NSRect) {
        if staged, let status {
            FolderColors.selected(status).setFill()
        } else if let status, let colour = FolderColors.background(status) {
            colour.setFill()
        } else {
            NSColor.textBackgroundColor.setFill()
        }
        bounds.fill()
        if isGutter {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isGutter else { return }
        FolderColors.selected(status ?? .unchanged).setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        (isSelected || staged) && !isGutter ? .emphasized : .normal
    }
}

/// Name, date or size cell: an optional icon and one line of text.
@MainActor
final class FolderCell: NSTableCellView {
    var selectedOnColour = false

    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            addSubview(image)
            imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        }
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(text: String, icon: NSImage?) {
        textField?.stringValue = text
        imageView?.image = icon
    }
}

/// Gutter cell: a small spinner while the row waits for the deep pass.
@MainActor
final class GutterCell: NSTableCellView {
    private let spinner = NSProgressIndicator()
    let stageButton = StageButton()

    init() {
        super.init(frame: .zero)
        identifier = FolderScopeView.gutterCell
        stageButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stageButton)
        NSLayoutConstraint.activate([
            stageButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            stageButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            stageButton.topAnchor.constraint(equalTo: topAnchor),
            stageButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isPending = false {
        didSet {
            if isPending { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }
}

/// "Show: [x] N Changed [x] N Unchanged [x] N Unmatched".
@MainActor
final class FolderBottomBar: BarView {
    let showLabel = NSTextField(labelWithString: "Show:")
    let changedButton = NSButton(checkboxWithTitle: "0 Changed", target: nil, action: nil)
    let unchangedButton = NSButton(checkboxWithTitle: "0 Unchanged", target: nil, action: nil)
    let unmatchedButton = NSButton(checkboxWithTitle: "0 Unmatched", target: nil, action: nil)

    var filterButtons: [NSButton] { [changedButton, unchangedButton, unmatchedButton] }

    let copyRightButton = NSButton(image: NSImage(systemSymbolName: "arrow.right.to.line", accessibilityDescription: "Copy to Right")!,
                                   target: nil, action: nil)
    let copyLeftButton = NSButton(image: NSImage(systemSymbolName: "arrow.left.to.line", accessibilityDescription: "Copy to Left")!,
                                  target: nil, action: nil)
    /// "Nothing to copy", "1 file to copy", "Copying name…".
    let copyStatus = NSTextField(labelWithString: FolderBottomBar.idleStatus)
    /// "Copy"; "Cancel" during a copy; "Cancelling…" once asked to stop.
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let progress = NSProgressIndicator()

    static let idleStatus = "Nothing to copy"

    init() {
        super.init(hairline: .top)
        for (button, id, tip) in [(copyRightButton, "copyRight", "Copy the selected items to the right (\u{2318}\u{2192})"),
                                  (copyLeftButton, "copyLeft", "Copy the selected items to the left (\u{2318}\u{2190})")] {
            button.bezelStyle = .smallSquare
            button.controlSize = .small
            button.toolTip = tip
            button.setAccessibilityIdentifier("prism.folder.\(id)")
            addSubview(button)
        }
        copyStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyStatus.textColor = .secondaryLabelColor
        copyStatus.alignment = .right
        copyStatus.lineBreakMode = .byTruncatingMiddle
        copyStatus.setAccessibilityIdentifier("prism.folder.copyStatus")
        copyButton.controlSize = .small
        copyButton.bezelStyle = .push
        copyButton.isEnabled = false
        copyButton.toolTip = "Copy the staged items (\u{2318}\u{21A9}; hold Option to skip the summary)"
        copyButton.setAccessibilityIdentifier("prism.folder.copy")
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.setAccessibilityIdentifier("prism.folder.copyProgress")
        for view in [copyStatus, copyButton, progress] as [NSView] { addSubview(view) }
        showLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        showLabel.textColor = .secondaryLabelColor
        addSubview(showLabel)
        for (button, id) in zip(filterButtons, ["changed", "unchanged", "unmatched"]) {
            button.state = .on
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setAccessibilityIdentifier("prism.filter.\(id)")
            addSubview(button)
        }
    }

    /// Shows the staged count, or the copy in progress.
    func setCopyState(staged: Int, copying: CopyProgress?, cancelling: Bool) {
        if let copying {
            let verb = copying.phase == .preparing ? "Preparing" : (copying.phase == .replacing ? "Replacing" : "Copying")
            copyStatus.stringValue = cancelling ? "Stopping\u{2026}" : "\(verb) \u{201C}\(copying.name)\u{201D}\u{2026}"
            progress.isHidden = false
            progress.doubleValue = copying.fraction
            copyButton.title = cancelling ? "Cancelling\u{2026}" : "Cancel"
            copyButton.isEnabled = !cancelling
            copyButton.bezelColor = nil
            copyButton.keyEquivalent = ""
        } else {
            copyStatus.stringValue = staged == 0 ? Self.idleStatus : "\(staged) \(staged == 1 ? "file" : "files") to copy"
            progress.isHidden = true
            copyButton.title = "Copy"
            copyButton.isEnabled = staged > 0
            // The prominent (accent) look while something is staged.
            copyButton.bezelColor = staged > 0 ? .controlAccentColor : nil
        }
        copyRightButton.isEnabled = copying == nil
        copyLeftButton.isEnabled = copying == nil
        needsLayout = true
    }

    func setCounts(_ counts: FolderCounts) {
        changedButton.title = "\(counts.changed) Changed"
        unchangedButton.title = "\(counts.unchanged) Unchanged"
        unmatchedButton.title = "\(counts.unmatched) Unmatched"
        needsLayout = true
    }

    var filter: FolderFilter {
        get {
            var filter: FolderFilter = []
            if changedButton.state == .on { filter.insert(.changed) }
            if unchangedButton.state == .on { filter.insert(.unchanged) }
            if unmatchedButton.state == .on { filter.insert(.unmatched) }
            // Nothing checked shows nothing.
            return filter.isEmpty ? FolderFilter(rawValue: 0x1) : filter
        }
        set {
            changedButton.state = newValue.contains(.changed) ? .on : .off
            unchangedButton.state = newValue.contains(.unchanged) ? .on : .off
            unmatchedButton.state = newValue.contains(.unmatched) ? .on : .off
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 12
        showLabel.sizeToFit()
        showLabel.frame.origin = NSPoint(x: x, y: floor((height - showLabel.frame.height) / 2))
        x += showLabel.frame.width + 8
        for button in filterButtons {
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x, y: floor((height - button.frame.height) / 2))
            x += button.frame.width + 12
        }
        let buttonSize = NSSize(width: 30, height: 20)
        copyRightButton.frame = NSRect(x: floor(bounds.midX - buttonSize.width - 1), y: floor((height - buttonSize.height) / 2),
                                       width: buttonSize.width, height: buttonSize.height)
        copyLeftButton.frame = NSRect(x: floor(bounds.midX + 1), y: floor((height - buttonSize.height) / 2),
                                      width: buttonSize.width, height: buttonSize.height)
        copyButton.sizeToFit()
        copyButton.frame.size.width = max(copyButton.frame.width, 70)
        copyButton.frame.origin = NSPoint(x: bounds.width - copyButton.frame.width - 10,
                                          y: floor((height - copyButton.frame.height) / 2))
        var right = copyButton.frame.minX - 8
        if !progress.isHidden {
            progress.frame = NSRect(x: right - 120, y: floor((height - 12) / 2), width: 120, height: 12)
            right = progress.frame.minX - 8
        }
        let left = max(copyLeftButton.frame.maxX + 12, x)
        copyStatus.sizeToFit()
        let width = min(copyStatus.frame.width, max(right - left, 0))
        copyStatus.frame = NSRect(x: right - width, y: floor((height - copyStatus.frame.height) / 2),
                                  width: width, height: copyStatus.frame.height)
    }
}
