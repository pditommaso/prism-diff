// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore

/// Editing, the 2-up merge actions, undo and saving for a comparison
/// window. The text lives in `session`; this part turns menu items, the
/// bottom-bar arrows and the swapped-in editor into session calls, and
/// re-diffs after every change.
extension ComparisonWindowController {
    /// Segment indices of the bottom bar's merge control.
    enum MergeSegment {
        static let leftMenu = 0
        static let copyToRight = 1
        static let copyToLeft = 2
        static let rightMenu = 3
    }

    func setUpEditing() {
        session.onChange = { [weak self] focus in
            // A new edit makes an earlier "Don't Save" answer void.
            self?.closingConfirmed = false
            self?.sessionChanged(focus)
        }
        blocksView.onBeginEditing = { [weak self] pane, selection, event in
            self?.beginEditing(pane: pane, selection: selection, event: event) ?? false
        }
        editor.textProvider = { [weak self] side, lines in self?.session.editableText(lines, of: side) ?? "" }
        editor.onCommit = { [weak self] region, text, caret in self?.commitEdit(region, text: text, caret: caret) }
        let control = bottomBar.mergeControl
        control.target = self
        control.action = #selector(mergeControlClicked(_:))
        control.setToolTip("More ways to merge", forSegment: MergeSegment.leftMenu)
        control.setToolTip("Copy to Right (\u{2318}\u{2192}); with \u{2325}, keep both", forSegment: MergeSegment.copyToRight)
        control.setToolTip("Copy to Left (\u{2318}\u{2190}); with \u{2325}, keep both", forSegment: MergeSegment.copyToLeft)
        control.setToolTip("More ways to merge", forSegment: MergeSegment.rightMenu)
        updateMergeControls()
    }

    // MARK: state

    /// The comparison was rebuilt or the text changed: the edited dot, the
    /// side markers and the merge arrows follow.
    func editingStateChanged() {
        window?.isDocumentEdited = session.isDirty
        pathBar.setEdited(a: session.isDirty(.a), b: session.isDirty(.b))
        updateMergeControls()
        onEditedChange?()
    }

    /// The window the user sees this comparison in: the host (folder)
    /// window of a text tab, or its own.
    var presentingWindow: NSWindow? { hostWindow ?? window }

    /// The presenting window, when a sheet can be shown on it (it is on
    /// screen, or in the Dock and brought back first).
    func sheetWindow() -> NSWindow? {
        guard let window = presentingWindow else { return nil }
        if window.isMiniaturized {
            window.deminiaturize(nil)
            return window
        }
        return window.isVisible ? window : nil
    }

    /// Hands back the text of an open editor, so that the session has
    /// every edit (before saving, closing or quitting).
    func commitEditing() {
        editor.commit()
    }

    /// True when there are unsaved edits, including text still in the
    /// editor (which is committed).
    var hasUnsavedChanges: Bool {
        commitEditing()
        return session.isDirty
    }

    /// True when a merge action can run now (a change is selected, nothing
    /// is loading and no text field has the keyboard).
    var canMerge: Bool {
        guard showsComparison, !isLoading, !editor.isEditing, blocksView.selectedChange != nil else { return false }
        return !(presentingWindow?.firstResponder is NSText)
    }

    func updateMergeControls() {
        let enabled = canMerge
        for segment in 0 ..< bottomBar.mergeControl.segmentCount {
            bottomBar.mergeControl.setEnabled(enabled, forSegment: segment)
        }
    }

    /// The session's text changed: re-diff it, keeping the view where it is
    /// and selecting what `focus` names.
    private func sessionChanged(_ focus: EditSession.Focus) {
        texts = session.texts
        editingStateChanged()
        editStarted = DispatchTime.now().uptimeNanoseconds
        quietLoad = true
        keepPositionOnLoad = blocksView.model != nil
        switch focus {
        case let .change(index):
            pendingFocus = nil
            pendingInitialChange = (index ?? blocksView.selectedChange).map { $0 + 1 }
        case .region:
            pendingFocus = focus
            pendingInitialChange = blocksView.selectedChange.map { $0 + 1 }
        }
        load(reread: false)
    }

    // MARK: free editing

    private func beginEditing(pane: DiffSide, selection: TextSelection, event: NSEvent?) -> Bool {
        guard showsComparison, !isLoading,
              let found = editor.region(pane: pane, row: selection.head.row) else { return false }
        if let refusal = session.refusal(toChange: found.side) {
            // A double click still selects the word; typing is refused.
            if event != nil { report(refusal) }
            return false
        }
        let began = editor.begin(pane: pane, selection: selection, event: event)
        updateMergeControls()
        return began
    }

    private func commitEdit(_ region: BlockEditor.Region, text: String, caret: (line: Int, offset: Int)) {
        pendingCaret = (region.pane, region.side, caret.line, caret.offset)
        do {
            try session.replaceLines(region.lines, of: region.side, with: text, selecting: blocksView.selectedChange)
        } catch {
            report(error)
        }
        updateMergeControls()
    }

    // MARK: merge actions

    @objc func copyToRight(_ sender: Any?) { applyMerge(.copyToRight) }
    @objc func copyToLeft(_ sender: Any?) { applyMerge(.copyToLeft) }
    @objc func keepBothLeftFirst(_ sender: Any?) { applyMerge(.keepBothLeftFirst) }
    @objc func keepBothRightFirst(_ sender: Any?) { applyMerge(.keepBothRightFirst) }

    /// Merge > Reset Selection: the selected change goes back to the text it
    /// had before any merge choice.
    @objc func resetSelection(_ sender: Any?) {
        guard canMerge, let model = blocksView.model, let index = blocksView.selectedChange else {
            NSSound.beep()
            return
        }
        do {
            try session.reset(change: index, in: model)
        } catch {
            report(error)
        }
    }

    /// Applies a merge choice to the selected change.
    func applyMerge(_ choice: MergeChoice) {
        guard canMerge, let model = blocksView.model, let index = blocksView.selectedChange else {
            NSSound.beep()
            return
        }
        do {
            try session.merge(choice, change: index, in: model)
            PerfLog.record("merge", ["choice": choice.rawValue, "change": index + 1])
        } catch {
            report(error)
        }
    }

    @objc func mergeControlClicked(_ sender: NSSegmentedControl) {
        let alternate = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        switch sender.selectedSegment {
        case MergeSegment.copyToRight: applyMerge(alternate ? .keepBothLeftFirst : .copyToRight)
        case MergeSegment.copyToLeft: applyMerge(alternate ? .keepBothRightFirst : .copyToLeft)
        case MergeSegment.leftMenu, MergeSegment.rightMenu:
            let menu = mergeMenu()
            let width = sender.width(forSegment: sender.selectedSegment)
            var x: CGFloat = 0
            for segment in 0 ..< sender.selectedSegment { x += sender.width(forSegment: segment) }
            if width == 0 { x = sender.selectedSegment == 0 ? 0 : sender.bounds.width - 20 }
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: sender.bounds.height + 2), in: sender)
        default: break
        }
    }

    /// The pop-up menu of the merge control's ▾ segments.
    func mergeMenu() -> NSMenu {
        let menu = NSMenu(title: "Merge")
        for (title, action) in [
            (MergeChoice.keepBothLeftFirst.title, #selector(keepBothLeftFirst(_:))),
            (MergeChoice.keepBothRightFirst.title, #selector(keepBothRightFirst(_:))),
            ("Reset Selection", #selector(resetSelection(_:))),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    /// Shows why an edit, merge or save did not happen: a sheet on a
    /// visible window, the perf log (and `lastRefusal`) always.
    func report(_ error: any Error) {
        let refusal = error as? EditSession.Refusal
            ?? EditSession.Refusal(title: "The change could not be made.", message: "\(error)")
        lastRefusal = refusal
        PerfLog.record("editRefused", ["title": refusal.title, "message": refusal.message])
        guard let window = sheetWindow() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = refusal.title
        alert.informativeText = refusal.message
        alert.beginSheetModal(for: window)
    }

    // MARK: saving

    /// File > Save: writes the sides with unsaved changes.
    @objc func saveComparison(_ sender: Any?) {
        commitEditing()
        save([.a, .b].filter { session.isDirty($0) }, confirmed: false)
    }

    /// File > Save All: every comparison with unsaved changes, in windows
    /// and in folder windows' tabs.
    @objc func saveAllComparisons(_ sender: Any?) {
        for controller in ComparisonWindowController.all() where controller.hasUnsavedChanges {
            controller.save([.a, .b].filter { controller.session.isDirty($0) }, confirmed: false)
        }
    }

    /// Every text comparison of the app: windows and text tabs.
    static func all() -> [ComparisonWindowController] {
        if let app = NSApp.delegate as? AppDelegate { return app.textComparisons }
        return NSApp.windows.compactMap { $0.windowController as? ComparisonWindowController }
    }

    /// File > Revert to Saved: reads both files again, dropping the edits.
    @objc func revertComparisonToSaved(_ sender: Any?) {
        commitEditing()
        guard session.isDirty else { return }
        guard let window = sheetWindow() else {
            reload()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Revert to the saved files?"
        alert.informativeText = "Your unsaved changes to \u{201C}\(title)\u{201D} will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.reload() }
        }
    }

    /// Saves `sides`. A side whose encoding does not round-trip, or whose
    /// file changed on disk, asks first (unless `confirmed`, which only
    /// covers the encoding). `done` gets true once every side is written;
    /// the return value is true when that happened synchronously.
    @discardableResult
    func save(_ sides: [DiffSide], confirmed: Bool, then done: ((Bool) -> Void)? = nil) -> Bool {
        var finished: Bool?
        saveNext(sides[...], confirmed: confirmed) { saved in
            finished = saved
            done?(saved)
        }
        return finished ?? false
    }

    private func saveNext(_ sides: ArraySlice<DiffSide>, confirmed: Bool, done: @escaping (Bool) -> Void) {
        guard let side = sides.first else {
            editingStateChanged()
            done(true)
            return
        }
        let rest = sides.dropFirst()
        let proceed: (Bool) -> Void = { [weak self] written in
            guard let self, written else {
                done(false)
                return
            }
            self.saveNext(rest, confirmed: confirmed, done: done)
        }
        if !confirmed, let format = session.text(side)?.format, !format.roundTrips {
            confirmLossySave(side) { [weak self] accepted in
                guard let self, accepted else {
                    done(false)
                    return
                }
                self.write(side, overwriting: false, completion: proceed)
            }
            return
        }
        write(side, overwriting: false, completion: proceed)
    }

    /// Writes one side, asking what to do when the file changed on disk.
    /// `completion` may run before this returns.
    private func write(_ side: DiffSide, overwriting: Bool, completion: @escaping (Bool) -> Void) {
        do {
            try session.save(side, overwritingExternalChanges: overwriting)
            PerfLog.record("saved", ["side": side == .a ? "a" : "b"])
            editingStateChanged()
            completion(true)
        } catch where error.kind == .changedOnDisk {
            guard let window = sheetWindow() else {
                report(error)
                completion(false)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = error.title
            alert.informativeText = error.message + " You can overwrite them, or revert to the file on disk and lose "
                + "your changes."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Revert")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertSecondButtonReturn: self.write(side, overwriting: true, completion: completion)
                case .alertThirdButtonReturn:
                    self.reload()
                    completion(false)
                default: completion(false)
                }
            }
        } catch {
            report(error)
            editingStateChanged()
            completion(false)
        }
    }

    private func confirmLossySave(_ side: DiffSide, completion: @escaping (Bool) -> Void) {
        let name = (side == .a ? urlA : urlB).lastPathComponent
        guard let window = sheetWindow() else {
            report(EditSession.Refusal(title: "\u{201C}\(name)\u{201D} was not saved.",
                                       message: "Its encoding does not round-trip; saving needs a confirmation."))
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save \u{201C}\(name)\u{201D} anyway?"
        alert.informativeText = "Some of its bytes could not be read exactly in its encoding, so saving it "
            + "will also change lines you did not edit."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
    }

    // MARK: closing

    /// Asks what to do with unsaved changes before the comparison closes:
    /// Save, Don't Save or Cancel, on the presenting window. `done` gets
    /// true when it may close. With no window to ask on, unsaved changes
    /// keep it open.
    func confirmClose(_ done: @escaping (Bool) -> Void) {
        guard hasUnsavedChanges, !closingConfirmed else {
            done(true)
            return
        }
        guard let window = sheetWindow() else {
            report(EditSession.Refusal(title: "\u{201C}\(title)\u{201D} has unsaved changes.",
                                       message: "Save or revert them before closing it."))
            done(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to \u{201C}\(title)\u{201D}?"
        alert.informativeText = "If you don\u{2019}t save, your changes will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don\u{2019}t Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.save([.a, .b].filter { self.session.isDirty($0) }, confirmed: false) { saved in done(saved) }
            case .alertThirdButtonReturn:
                self.closingConfirmed = true
                done(true)
            default:
                done(false)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges, !closingConfirmed else { return true }
        confirmClose { [weak self] proceed in
            guard proceed, let self else { return }
            self.closingConfirmed = true
            self.window?.close()
        }
        return false
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        session.undoManager
    }

    // MARK: menus

    /// Enables the editing items; nil for items this part does not handle.
    func validateEditingItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(copyToRight(_:)), #selector(copyToLeft(_:)):
            return canMerge
        case #selector(keepBothLeftFirst(_:)), #selector(keepBothRightFirst(_:)):
            // Keeping both sides needs text on both (not an insert or a
            // delete).
            guard canMerge, let model = blocksView.model, let index = blocksView.selectedChange,
                  model.layout.changes.indices.contains(index) else { return false }
            let block = model.layout.blocks[model.layout.changes[index]]
            return !block.isInsert && !block.isDelete
        case #selector(resetSelection(_:)):
            guard canMerge, let model = blocksView.model, let index = blocksView.selectedChange else { return false }
            return session.canReset(change: index, in: model)
        case #selector(saveComparison(_:)), #selector(revertComparisonToSaved(_:)):
            return session.isDirty || editor.isEditing
        case #selector(saveAllComparisons(_:)):
            return NSApp.windows.contains { ($0.windowController as? ComparisonWindowController)?.session.isDirty == true }
                || editor.isEditing
        default:
            return nil
        }
    }
}
