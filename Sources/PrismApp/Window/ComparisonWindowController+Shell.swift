// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import AVFoundation
import DiffCore

/// The window-shell commands of a text comparison: the file shelf and its
/// A/B navigation, the path bar's sibling menus, pasting the clipboard as
/// a file, spelling and speech.
extension ComparisonWindowController {
    func setUpShelf() {
        shelfView.onSetA = { [weak self] index in self?.updateShelf { $0.setA(index); return true } }
        shelfView.onSetB = { [weak self] index in self?.updateShelf { $0.setB(index); return true } }
        shelfView.onRemove = { [weak self] index in self?.updateShelf { $0.remove(index) } }
        shelfView.onAdd = { [weak self] in self?.addFilesToComparison(nil) }
        shelfView.onNext = { [weak self] in self?.selectNextB(nil) }
        shelfView.onPrevious = { [weak self] in self?.selectPreviousB(nil) }
        shelfView.show(shelf)
        pathBar.onChoose = { [weak self] side, url in self?.choose(url, for: side) }
    }

    // MARK: shelf

    var isShelfVisible: Bool { content.shelf != nil }

    func setShelfVisible(_ visible: Bool) {
        content.shelf = visible ? shelfView : nil
        shelfView.show(shelf)
        recordShelf()
    }

    /// View > Toggle File Shelf (Command-/).
    @objc func toggleFileShelf(_ sender: Any?) {
        setShelfVisible(!isShelfVisible)
    }

    /// Puts `entries` on the shelf and compares entries `a` and `b`. More
    /// than two files show the shelf.
    func setShelfFiles(_ entries: [ShelfEntry], a: Int, b: Int) {
        shelf = ShelfModel(files: entries, a: a, b: b)
        if entries.count > 2 { content.shelf = shelfView }
        applyShelf()
    }

    /// Changes the shelf with `change` (false: nothing to do, beep). When
    /// A or B changes, the comparison shows the new pair, after asking
    /// about unsaved edits.
    func updateShelf(_ change: (inout ShelfModel) -> Bool) {
        var next = shelf
        guard change(&next) else { return NSSound.beep() }
        let pairChanged = next.entryA != shelf.entryA || next.entryB != shelf.entryB
        guard pairChanged else {
            shelf = next
            updateChrome()
            recordShelf()
            return
        }
        guard hasUnsavedChanges else {
            shelf = next
            applyShelf()
            return
        }
        confirmClose { [weak self] proceed in
            guard proceed, let self else { return }
            self.closingConfirmed = false
            self.shelf = next
            self.applyShelf()
        }
    }

    /// Compares the shelf's A and B.
    func applyShelf() {
        guard let a = shelf.entryA, let b = shelf.entryB else { return }
        var snapshots: Set<DiffSide> = []
        if a.isSnapshot { snapshots.insert(.a) }
        if b.isSnapshot { snapshots.insert(.b) }
        showFiles(a: a.url, b: b.url, display: (a.display, b.display), snapshots: snapshots)
        recordShelf()
    }

    private func recordShelf() {
        guard PerfLog.isEnabled else { return }
        PerfLog.record("shelf", [
            "files": shelf.files.map { $0.url.lastPathComponent },
            "a": shelf.a, "b": shelf.b,
            "visible": isShelfVisible,
            "title": title,
        ])
    }

    /// Edit > Select Next B (→) and the shelf's "›".
    @objc func selectNextB(_ sender: Any?) { updateShelf { $0.stepB(1) } }
    /// Edit > Select Previous B (←) and the shelf's "‹".
    @objc func selectPreviousB(_ sender: Any?) { updateShelf { $0.stepB(-1) } }
    /// Edit > Select Next A (⌥→).
    @objc func selectNextA(_ sender: Any?) { updateShelf { $0.stepA(1) } }
    /// Edit > Select Previous A (⌥←).
    @objc func selectPreviousA(_ sender: Any?) { updateShelf { $0.stepA(-1) } }
    /// Edit > Select Next A & B.
    @objc func selectNextAAndB(_ sender: Any?) { updateShelf { $0.stepBoth(1) } }
    /// Edit > Select Previous A & B.
    @objc func selectPreviousAAndB(_ sender: Any?) { updateShelf { $0.stepBoth(-1) } }

    /// Adds files to the shelf; with `makeB`, the first becomes B.
    func addShelfFiles(_ entries: [ShelfEntry], makeB: Bool) {
        guard !entries.isEmpty else { return }
        content.shelf = shelfView
        updateShelf { $0.add(entries, makeB: makeB); return true }
    }

    /// The shelf's "+": choose more files for this comparison.
    @objc func addFilesToComparison(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = urlB.deletingLastPathComponent()
        panel.message = "Choose files to add to this comparison."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        addShelfFiles(panel.urls.map { ShelfEntry(url: $0) }, makeB: false)
    }

    /// A sibling chosen in the path bar replaces that side's file.
    func choose(_ url: URL, for side: PathBarView.Side) {
        guard !AppDelegate.isDirectory(url) else { return NSSound.beep() }
        updateShelf { $0.replace(sideA: side == .a, with: ShelfEntry(url: url)); return true }
    }

    // MARK: clipboard

    /// Edit > Paste outside a text field: the clipboard becomes a file of
    /// the comparison, as Paste to Comparison.
    @objc func paste(_ sender: Any?) { pasteToComparison(sender) }

    /// Edit > Paste to Comparison: the clipboard's text becomes B.
    @objc func pasteToComparison(_ sender: Any?) {
        guard let url = ClipboardSnippets.writeClipboard() else { return NSSound.beep() }
        addShelfFiles([ShelfEntry(url: url, display: .nameOnly)], makeB: true)
    }

    // MARK: spelling and speech

    /// The text of one side, as compared.
    func text(of side: DiffSide) -> String? {
        guard let texts else { return nil }
        return String(decoding: side == .a ? texts.a.bytes : texts.b.bytes, as: UTF8.self)
    }

    /// Edit > Spelling > Check Spelling: finds the next misspelled word of
    /// B (from the last one found) and shows it with the find bar.
    @objc func checkSpelling(_ sender: Any?) {
        guard let text = text(of: .b) else { return NSSound.beep() }
        let checker = NSSpellChecker.shared
        let length = (text as NSString).length
        var range = checker.checkSpelling(of: text, startingAt: min(spellingOffset, length))
        if range.location == NSNotFound, spellingOffset > 0 {
            range = checker.checkSpelling(of: text, startingAt: 0)
        }
        guard range.location != NSNotFound, range.length > 0 else {
            spellingOffset = 0
            return NSSound.beep()
        }
        spellingOffset = range.location + range.length
        let word = (text as NSString).substring(with: range)
        checker.updateSpellingPanel(withMisspelledWord: word)
        find.show()
        find.find(word)
    }

    /// Edit > Spelling > Check Spelling While Typing (in the editor).
    @objc func toggleContinuousSpellChecking(_ sender: Any?) {
        checksSpellingWhileTyping.toggle()
        (presentingWindow?.firstResponder as? NSTextView)?.isContinuousSpellCheckingEnabled = checksSpellingWhileTyping
    }

    /// Edit > Speech > Start Speaking: the selected text, or B.
    @objc func startSpeaking(_ sender: Any?) {
        guard let text = blocksView.selectedText() ?? text(of: .b), !text.isEmpty else { return NSSound.beep() }
        let synthesizer = speech ?? AVSpeechSynthesizer()
        speech = synthesizer
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    @objc func stopSpeaking(_ sender: Any?) { speech?.stopSpeaking(at: .immediate) }

    /// Enables the shell items; nil for items this part does not handle.
    func validateShellItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(toggleFileShelf(_:)):
            return true
        case #selector(selectNextB(_:)), #selector(selectPreviousB(_:)),
             #selector(selectNextA(_:)), #selector(selectPreviousA(_:)):
            return shelf.count > 2
        case #selector(selectNextAAndB(_:)), #selector(selectPreviousAAndB(_:)):
            return shelf.count >= 2
        case #selector(paste(_:)), #selector(pasteToComparison(_:)):
            return ClipboardSnippets.hasText
        case #selector(addFilesToComparison(_:)):
            return true
        case #selector(checkSpelling(_:)):
            return showsComparison
        case #selector(toggleContinuousSpellChecking(_:)):
            item.state = checksSpellingWhileTyping ? .on : .off
            return true
        case #selector(startSpeaking(_:)):
            return showsComparison && speech?.isSpeaking != true
        case #selector(stopSpeaking(_:)):
            return speech?.isSpeaking == true
        default:
            return nil
        }
    }
}

/// The clipboard's text as a file, so that it can be compared.
@MainActor
enum ClipboardSnippets {
    /// The pasteboard read (tests use a private one).
    static var pasteboard: NSPasteboard = .general

    static var hasText: Bool { pasteboard.string(forType: .string)?.isEmpty == false }

    /// Where snippets are written: a private folder in the temporary
    /// directory.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Prism-Clipboard", directoryHint: .isDirectory)
    }

    /// Removes the snippets not in `keeping` (paths), and the folder when
    /// none is left. Run at quit: snippets of windows that come back stay.
    static func cleanUp(keeping: Set<String>, in folder: URL = directory) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // /var and /private/var name the same folder.
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path(percentEncoded: false) }
        let kept = Set(keeping.map { resolved(URL(filePath: $0)) })
        var left = 0
        for item in items {
            if kept.contains(resolved(item)) {
                left += 1
            } else {
                try? fm.removeItem(at: item)
            }
        }
        if left == 0 { try? fm.removeItem(at: folder) }
    }

    /// Writes the clipboard's text to "Clipboard N.txt"; nil when the
    /// clipboard holds no text.
    static func writeClipboard() -> URL? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        let folder = directory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var number = 1
            var url = folder.appending(path: "Clipboard.txt")
            while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                number += 1
                url = folder.appending(path: "Clipboard \(number).txt")
            }
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            return url
        } catch {
            return nil
        }
    }
}
