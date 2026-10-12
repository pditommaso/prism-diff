// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import os
import PrismProtocol

/// A window for a three-way merge (`prism --merge`, `git mergetool`): A,
/// the result and B, conflict navigation, the merge choices, editing of the
/// result and saving it to the output file.
///
/// The window reports how it ended through `onFinish`: resolved when the
/// result was saved with every conflict resolved and nothing changed since.
/// Closing it while conflicts remain asks first (Review Conflicts, or Don't
/// Resolve, which closes it unresolved).
@MainActor
final class MergeWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSTextViewDelegate {
    static let defaultFrameSize = NSSize(width: 1354, height: 908)

    /// Layout of new merge windows, remembered apart from two-way ones;
    /// a first merge opens in Unified.
    static let viewModeKey = "prism.merge.viewMode"

    let session: MergeSession
    let tabStrip = TabStripView()
    let header = MergeHeaderView()
    let mergeView: MergeView
    let bottomBar: BottomBarView
    let placeholder = PlaceholderView()
    private let content = ComparisonContentView()

    /// Called once when the window closes, with whether the merge was
    /// resolved.
    var onFinish: ((_ resolved: Bool) -> Void)?
    /// Called when the window has closed.
    var onClose: ((MergeWindowController) -> Void)?

    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var finished = false
    /// The user chose Don't Resolve (or to close without saving).
    private var closingConfirmed = false
    /// The editor over a region of the result, while it is open.
    private(set) var editor: NSTextView?
    private(set) var editedRegion: Int?
    /// The editor's text when it opened: an editor left as it was never
    /// changes the result.
    private var editorStartText = ""
    /// The last refused save (also shown as a sheet).
    private(set) var lastRefusal: EditSession.Refusal?
    /// The question the window asked when closing was attempted (for tests).
    enum CloseQuestion: Equatable { case unresolvedConflicts, unsavedChanges }
    private(set) var pendingQuestion: CloseQuestion?

    init(files: MergeFiles, title: String? = nil) {
        session = MergeSession(files: files)
        let settings = TextSettings()
        mergeView = MergeView(font: settings.font, theme: settings.theme)
        let mode = AppDefaults.shared.string(forKey: Self.viewModeKey).flatMap(ViewMode.init(rawValue:)) ?? .unified
        mergeView.setMode(mode)
        bottomBar = BottomBarView(target: nil, previous: #selector(selectPreviousConflict(_:)),
                                  next: #selector(selectNextConflict(_:)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultFrameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.setFrame(NSRect(origin: .zero, size: Self.defaultFrameSize), display: false)
        window.contentMinSize = ComparisonWindowController.minimumContentSize
        let name = title ?? files.output.lastPathComponent
        // The title bar names the app; the merge is named by the tab strip.
        window.title = PrismWindowTitle.default
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("prism.merge")
        window.delegate = self
        window.autorecalculatesKeyViewLoop = true
        DisplayOptions.applyMotion(to: window)
        window.setAccessibilityLabel(name)
        NSApp.changeWindowsItem(window, title: name, filename: false)

        tabStrip.setTitle(name, fileCount: files.base == nil ? 2 : 3)
        header.setNames(a: files.a.lastPathComponent, b: files.b.lastPathComponent)
        header.setUnresolved(0)
        mergeView.onColumnsChange = { [weak self] columns in
            guard let self else { return }
            self.header.setColumns(columns, unified: self.mergeView.mode == .unified)
        }
        mergeView.onSelect = { [weak self] region in self?.select(region: region) }
        mergeView.onEdit = { [weak self] region in self?.beginEditing(region: region) }

        bottomBar.previousButton.target = self
        bottomBar.nextButton.target = self
        bottomBar.previousButton.toolTip = "Previous conflict (\u{2325}\u{2318}\u{2191})"
        bottomBar.nextButton.toolTip = "Next conflict (\u{2325}\u{2318}\u{2193})"
        bottomBar.previousButton.setAccessibilityIdentifier("prism.previousConflict")
        bottomBar.nextButton.setAccessibilityIdentifier("prism.nextConflict")
        bottomBar.layoutControl.target = self
        bottomBar.layoutControl.action = #selector(layoutControlChanged(_:))
        bottomBar.layoutControl.selectedSegment = mode.index
        // A merge always compares exactly (see MergeSession.compute).
        bottomBar.ignoreWhitespaceButton.state = .off
        bottomBar.ignoreWhitespaceButton.isEnabled = false
        bottomBar.ignoreWhitespaceButton.toolTip = "A merge always compares whitespace exactly, so no edit is lost"
        let control = bottomBar.mergeControl
        control.target = self
        control.action = #selector(mergeControlClicked(_:))
        control.setToolTip("More choices", forSegment: 0)
        control.setToolTip("Choose Left (\u{2318}\u{2192}); with \u{2325}, both, left first", forSegment: 1)
        control.setToolTip("Choose Right (\u{2318}\u{2190}); with \u{2325}, both, right first", forSegment: 2)
        control.setToolTip("More choices", forSegment: 3)

        content.tabStrip = tabStrip
        content.pathBar = header
        content.bottomBar = bottomBar
        content.body = placeholder
        window.contentView = content
        window.initialFirstResponder = mergeView.canvas

        session.onChange = { [weak self] region in self?.sessionChanged(region) }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: TextSettings.didChange, object: nil)
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window and starts merging.
    func present(cascadingFrom previous: NSWindow? = nil) {
        guard let window else { return }
        if let previous {
            window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            window.center()
        }
        showWindow(nil)
        load()
        DispatchQueue.main.async { MainActor.assumeIsolated { MergeMenuContext.refresh() } }
    }

    // MARK: loading

    /// Reads the files and merges them off the main thread.
    func load() {
        loadTask?.cancel()
        generation += 1
        let current = generation
        isLoading = true
        let files = session.files
        let source = TextSources.current
        placeholder.showLoading()
        content.body = placeholder
        updateState()
        loadTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try MergeSession.compute(files: files, source: source) }
            }.value
            guard let self, self.generation == current else { return }
            self.finishLoad(outcome)
        }
    }

    private func finishLoad(_ outcome: Result<(texts: (LoadedText, LoadedText, LoadedText?), result: Merge3Result), any Error>) {
        isLoading = false
        switch outcome {
        case let .success(value):
            content.body = mergeView
            content.layoutSubtreeIfNeeded()
            session.load(texts: value.texts, result: value.result)
            // Start on the first conflict, else the first difference.
            if let first = session.conflicts.first ?? session.differences.first {
                select(region: first)
            }
            PerfLog.record("mergeLoaded", ["regions": value.result.regions.count,
                                           "conflicts": value.result.conflictCount,
                                           "unresolved": session.unresolvedCount,
                                           "mode": mergeView.mode.rawValue])
        case let .failure(error):
            placeholder.showMessage(ComparisonWindowController.describe(error))
            content.body = placeholder
            PerfLog.record("loadFailed", ["message": ComparisonWindowController.describe(error)])
        }
        updateState()
    }

    var showsMerge: Bool { content.body === mergeView && session.result != nil }

    // MARK: state

    private(set) var selectedRegion: Int?

    private func sessionChanged(_ region: Int?) {
        mergeView.display = MergeDisplay(session: session)
        if let region { selectedRegion = region }
        mergeView.selectedRegion = selectedRegion
        updateState()
    }

    /// Header, bottom bar, edited dot and merge arrows follow the session.
    func updateState() {
        header.setUnresolved(session.result == nil ? 0 : session.unresolvedCount)
        if session.result == nil { header.statusLabel.stringValue = "" }
        window?.isDocumentEdited = session.isDirty
        bottomBar.changeLabel.stringValue = conflictLabel
        bottomBar.changeLabel.setAccessibilityValue(conflictLabel)
        let conflicts = session.conflicts.count
        bottomBar.previousButton.isEnabled = conflicts > 0
        bottomBar.nextButton.isEnabled = conflicts > 0
        let canChoose = selectedRegion.map { session.result?.regions[$0].kind != .equal } ?? false
        for segment in 0 ..< bottomBar.mergeControl.segmentCount {
            bottomBar.mergeControl.setEnabled(canChoose == true, forSegment: segment)
        }
        bottomBar.needsLayout = true
    }

    /// "Conflict N of M" with ⚠ while that conflict is unresolved and ✓
    /// once it is; "No Conflicts" when there is none.
    var conflictLabel: String {
        guard session.result != nil else { return "" }
        let conflicts = session.conflicts
        guard !conflicts.isEmpty else { return "No Conflicts" }
        let current = selectedRegion.flatMap { conflicts.firstIndex(of: $0) }
            ?? conflicts.firstIndex { $0 >= (selectedRegion ?? 0) } ?? 0
        let mark = session.isUnresolved(conflicts[current]) ? "\u{26A0}" : "\u{2713}"
        return "Conflict \(current + 1) of \(conflicts.count) \(mark)"
    }

    /// Selects region `index` and scrolls it into view.
    func select(region index: Int) {
        commitEditing()
        selectedRegion = index
        mergeView.selectedRegion = index
        mergeView.reveal(region: index)
        updateState()
        PerfLog.record("mergeSelection", ["region": index, "label": conflictLabel])
    }

    // MARK: navigation

    private func step(_ candidates: [Int], forward: Bool) {
        guard !candidates.isEmpty else { return }
        let current = selectedRegion ?? (forward ? -1 : Int.max)
        let next = forward ? candidates.first { $0 > current } ?? candidates.first!
                           : candidates.last { $0 < current } ?? candidates.last!
        select(region: next)
    }

    @objc func selectNextConflict(_ sender: Any?) { step(session.conflicts, forward: true) }
    @objc func selectPreviousConflict(_ sender: Any?) { step(session.conflicts, forward: false) }
    @objc func selectNextChange(_ sender: Any?) { step(session.differences, forward: true) }
    @objc func selectPreviousChange(_ sender: Any?) { step(session.differences, forward: false) }

    // MARK: choices (the Merge menu, renamed for three-way merges)

    /// Merge > Choose Left (⌘→): the selected region takes A's lines.
    @objc func copyToRight(_ sender: Any?) { choose(.a) }
    /// Merge > Choose Right (⌘←): B's lines.
    @objc func copyToLeft(_ sender: Any?) { choose(.b) }
    /// Merge > Choose Both (Left First) (⌥⌘→).
    @objc func keepBothLeftFirst(_ sender: Any?) { choose(.aThenB) }
    /// Merge > Choose Both (Right First) (⌥⌘←).
    @objc func keepBothRightFirst(_ sender: Any?) { choose(.bThenA) }
    /// Merge > Reset Selection (⌥⌘⌫): back to what the merge decided.
    @objc func resetSelection(_ sender: Any?) {
        commitEditing()
        guard let region = selectedRegion else { return }
        session.reset(region: region)
    }

    func choose(_ choice: DiffCore.MergeChoice) {
        commitEditing()
        guard let region = selectedRegion else { return }
        session.choose(choice, region: region)
        PerfLog.record("mergeChoice", ["choice": choice.name, "region": region,
                                       "unresolved": session.unresolvedCount, "label": conflictLabel])
    }

    @objc func mergeControlClicked(_ sender: NSSegmentedControl) {
        let alternate = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        switch sender.selectedSegment {
        case 1: choose(alternate ? .aThenB : .a)
        case 2: choose(alternate ? .bThenA : .b)
        case 0, 3:
            let menu = NSMenu()
            for (title, action) in [("Choose Left", #selector(copyToRight(_:))), ("Choose Right", #selector(copyToLeft(_:))),
                                    ("Choose Both (Left First)", #selector(keepBothLeftFirst(_:))),
                                    ("Choose Both (Right First)", #selector(keepBothRightFirst(_:))),
                                    ("Reset Selection", #selector(resetSelection(_:)))] {
                menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
            }
            menu.popUp(positioning: nil, at: NSPoint(x: sender.selectedSegment == 0 ? 0 : sender.bounds.width - 20,
                                                     y: sender.bounds.height + 2), in: sender)
        default: break
        }
    }

    // MARK: editing the result

    /// Opens an editor over region `index` of the result column.
    func beginEditing(region index: Int) {
        commitEditing()
        guard showsMerge, let rect = mergeView.outputRect(region: index) else { return }
        selectedRegion = index
        mergeView.selectedRegion = index
        let textView = NSTextView(frame: rect)
        textView.font = mergeView.metrics.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = mergeView.metrics.textInset - 2
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = session.editableText(ofRegion: index)
        editorStartText = textView.string
        textView.delegate = self
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityIdentifier("prism.mergeEditor")
        mergeView.canvas.addSubview(textView)
        editor = textView
        editedRegion = index
        window?.makeFirstResponder(textView)
        updateState()
    }

    /// Hands the editor's text to the session, if it was changed, and
    /// closes the editor. An editor left as it opened changes nothing (an
    /// unresolved conflict stays unresolved).
    func commitEditing() {
        guard let editor, let region = editedRegion else { return }
        let text = editor.string
        self.editor = nil
        editedRegion = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        guard text != editorStartText else { return }
        session.edit(region: region, text: text)
    }

    /// Closes the editor without keeping its text.
    func cancelEditing() {
        editor?.delegate = nil
        editor?.removeFromSuperview()
        editor = nil
        editedRegion = nil
    }

    func textDidEndEditing(_ notification: Notification) { commitEditing() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            cancelEditing()
            window?.makeFirstResponder(mergeView.canvas)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        // Grow the editor with its text, at least over the region's rows.
        guard let editor, let region = editedRegion, let rect = mergeView.outputRect(region: region) else { return }
        let lines = max(editor.string.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        editor.frame.size.height = max(rect.height, CGFloat(lines) * mergeView.metrics.lineHeight + 4)
    }

    // MARK: layout and options

    @objc func showBlocksLayout(_ sender: Any?) { setMode(.blocks) }
    @objc func showFluidLayout(_ sender: Any?) { setMode(.fluid) }
    @objc func showUnifiedLayout(_ sender: Any?) { setMode(.unified) }

    @objc private func layoutControlChanged(_ sender: NSSegmentedControl) {
        guard ViewMode.allCases.indices.contains(sender.selectedSegment) else { return }
        setMode(ViewMode.allCases[sender.selectedSegment])
    }

    func setMode(_ mode: ViewMode) {
        commitEditing()
        bottomBar.layoutControl.selectedSegment = mode.index
        AppDefaults.shared.set(mode.rawValue, forKey: Self.viewModeKey)
        mergeView.setMode(mode)
        header.setColumns(mergeView.columnFrames, unified: mode == .unified)
        if let selectedRegion { mergeView.reveal(region: selectedRegion) }
        PerfLog.record("layout", ["mode": mode.rawValue])
    }

    /// View > Ignore Whitespace does not apply to a merge (always exact).
    @objc func toggleIgnoreWhitespace(_ sender: Any?) {}

    @objc func increaseTextSize(_ sender: Any?) { resize(by: 1) }
    @objc func decreaseTextSize(_ sender: Any?) { resize(by: -1) }

    private func resize(by delta: CGFloat) {
        commitEditing()
        let size = min(max(mergeView.metrics.font.pointSize + delta, TextSettings.minimumFontSize),
                       TextSettings.maximumFontSize)
        mergeView.metrics = TextMetrics(font: NSFontManager.shared.convert(mergeView.metrics.font, toSize: size))
    }

    @objc private func settingsChanged(_ note: Notification) {
        let settings = TextSettings()
        mergeView.theme = settings.theme
    }

    // MARK: saving

    /// File > Save: writes the result to the output file.
    @discardableResult
    @objc func saveComparison(_ sender: Any?) -> Bool { save(allowingLoss: false) }

    /// Saves the result. A save that would write replaced characters asks
    /// first (Save Anyway or Cancel); until then nothing is written.
    @discardableResult
    func save(allowingLoss: Bool) -> Bool {
        commitEditing()
        do {
            try session.save(allowingLoss: allowingLoss)
            lastRefusal = nil
            updateState()
            PerfLog.record("mergeSaved", ["unresolved": session.unresolvedCount, "resolved": session.isResolved])
            return true
        } catch {
            lastRefusal = error
            PrismLog.merge.error("merge result not saved: \(error.description, privacy: .private)")
            PerfLog.record("saveRefused", ["message": error.description])
            if error.kind == .lossy {
                askToSaveWithLoss(error)
            } else {
                showAlert(title: error.title, message: error.message)
            }
            return false
        }
    }

    private func askToSaveWithLoss(_ refusal: EditSession.Refusal) {
        guard let window, window.isVisible, !AppIPCService.isTesting else { return }
        let alert = NSAlert()
        alert.messageText = refusal.title
        alert.informativeText = refusal.message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save Anyway")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertSecondButtonReturn { self?.save(allowingLoss: true) }
            }
        }
    }

    @objc func saveAllComparisons(_ sender: Any?) { saveComparison(sender) }

    /// File > Revert to Saved: merges the files again from scratch.
    @objc func revertComparisonToSaved(_ sender: Any?) {
        cancelEditing()
        session.discardChoices()
        load()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window, window.isVisible, !AppIPCService.isTesting {
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: closing

    /// What closing the window must ask first, or nil when it may close.
    /// It changes nothing (an open editor's text counts only once committed).
    var closeQuestion: CloseQuestion? {
        if closingConfirmed || session.result == nil { return nil }
        if session.unresolvedCount > 0 { return .unresolvedConflicts }
        if session.isDirty { return .unsavedChanges }
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitEditing()
        guard let question = closeQuestion else { return true }
        pendingQuestion = question
        PerfLog.record("mergeCloseQuestion", ["question": question == .unresolvedConflicts ? "unresolved" : "unsaved"])
        let alert = NSAlert()
        switch question {
        case .unresolvedConflicts:
            alert.messageText = "\u{201C}\(session.files.output.lastPathComponent)\u{201D} still has unresolved conflicts. "
                + "Do you want to review them?"
            alert.informativeText = "If you close the merge now, it is not resolved: the tool that started it will "
                + "treat it as failed."
            alert.addButton(withTitle: "Review Conflicts")
            alert.addButton(withTitle: "Don\u{2019}t Resolve")
        case .unsavedChanges:
            alert.messageText = "Do you want to save the merged \u{201C}\(session.files.output.lastPathComponent)\u{201D}?"
            alert.informativeText = "Only a saved result counts as resolved."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don\u{2019}t Save")
            alert.addButton(withTitle: "Cancel")
        }
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated { self?.answer(question, response) }
        }
        return false
    }

    /// The answer to a close question: Review Conflicts (the first button)
    /// selects the first unresolved conflict and keeps the window open;
    /// Don't Resolve closes it unresolved. For unsaved changes: Save, Don't
    /// Save (closes unresolved) or Cancel.
    func answer(_ question: CloseQuestion, _ response: NSApplication.ModalResponse) {
        pendingQuestion = nil
        switch (question, response) {
        case (.unresolvedConflicts, .alertFirstButtonReturn):
            if let first = session.conflicts.first(where: session.isUnresolved) { select(region: first) }
            PerfLog.record("mergeReview", ["label": conflictLabel])
        case (.unresolvedConflicts, _):
            closingConfirmed = true
            window?.close()
        case (.unsavedChanges, .alertFirstButtonReturn):
            if saveComparison(nil) { window?.close() }
        case (.unsavedChanges, .alertSecondButtonReturn):
            closingConfirmed = true
            window?.close()
        default:
            break
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor == nil ? session.undoManager : nil
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        generation += 1
        cancelEditing()
        NotificationCenter.default.removeObserver(self)
        finish()
        onClose?(self)
    }

    /// Reports the outcome now (the app is quitting): resolved when the
    /// saved result is final, as when the window closes.
    func finishNow() {
        cancelEditing()
        finish()
    }

    /// Reports the outcome once.
    private func finish() {
        guard !finished else { return }
        finished = true
        let resolved = session.isResolved
        PerfLog.record("mergeFinished", ["resolved": resolved])
        onFinish?(resolved)
    }

    // MARK: menus

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let region = selectedRegion.flatMap { session.result?.regions.indices.contains($0) == true ? $0 : nil }
        let differs = region.map { session.result!.regions[$0].kind != .equal } ?? false
        switch menuItem.action {
        case #selector(copyToRight(_:)), #selector(copyToLeft(_:)),
             #selector(keepBothLeftFirst(_:)), #selector(keepBothRightFirst(_:)):
            return showsMerge && differs
        case #selector(resetSelection(_:)):
            return showsMerge && (region.map(session.canReset(region:)) ?? false)
        case #selector(selectNextConflict(_:)), #selector(selectPreviousConflict(_:)):
            return showsMerge && !session.conflicts.isEmpty
        case #selector(selectNextChange(_:)), #selector(selectPreviousChange(_:)):
            return showsMerge && !session.differences.isEmpty
        case #selector(showBlocksLayout(_:)), #selector(showFluidLayout(_:)), #selector(showUnifiedLayout(_:)):
            let mode: ViewMode = menuItem.action == #selector(showBlocksLayout(_:)) ? .blocks
                : menuItem.action == #selector(showFluidLayout(_:)) ? .fluid : .unified
            menuItem.state = mergeView.mode == mode ? .on : .off
            return true
        case #selector(toggleIgnoreWhitespace(_:)):
            menuItem.state = .off
            return false
        case #selector(saveComparison(_:)), #selector(saveAllComparisons(_:)):
            return showsMerge
        case #selector(revertComparisonToSaved(_:)):
            return showsMerge && session.undoManager.canUndo
        default:
            return true
        }
    }
}
