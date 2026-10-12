// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// One file on a comparison's shelf.
struct ShelfEntry: Equatable, Sendable {
    var url: URL
    /// How the path bar and the card show it (a clipboard snippet shows
    /// only its name).
    var display: PathBarView.Display = .path
    /// A private copy from `prism` (never edited).
    var isSnapshot = false
}

/// The files of a comparison and which two are compared: A and B are
/// distinct indices into `files`. Pure state, so the navigation rules are
/// testable on their own.
struct ShelfModel: Equatable, Sendable {
    private(set) var files: [ShelfEntry]
    private(set) var a: Int
    private(set) var b: Int

    init(files: [ShelfEntry], a: Int = 0, b: Int = 1) {
        self.files = files
        let count = max(files.count, 1)
        self.a = min(max(a, 0), count - 1)
        self.b = min(max(b, 0), count - 1)
        if self.a == self.b, files.count > 1 { self.b = (self.a + 1) % files.count }
    }

    var count: Int { files.count }
    var entryA: ShelfEntry? { files.indices.contains(a) ? files[a] : nil }
    var entryB: ShelfEntry? { files.indices.contains(b) ? files[b] : nil }

    /// B moves to the next (or previous) file, skipping A; false when no
    /// other file is left.
    @discardableResult
    mutating func stepB(_ delta: Int) -> Bool {
        guard let next = Self.step(from: b, by: delta, skipping: a, count: count) else { return false }
        b = next
        return true
    }

    /// A moves, skipping B.
    @discardableResult
    mutating func stepA(_ delta: Int) -> Bool {
        guard let next = Self.step(from: a, by: delta, skipping: b, count: count) else { return false }
        a = next
        return true
    }

    /// A and B both move by one file (with two files, they trade places).
    @discardableResult
    mutating func stepBoth(_ delta: Int) -> Bool {
        guard count >= 2 else { return false }
        a = ((a + delta) % count + count) % count
        b = ((b + delta) % count + count) % count
        return true
    }

    private static func step(from start: Int, by delta: Int, skipping other: Int, count: Int) -> Int? {
        guard count > 2 else { return nil }
        var index = start
        repeat {
            index = ((index + delta) % count + count) % count
        } while index == other
        return index == start ? nil : index
    }

    mutating func swapAB() { swap(&a, &b) }

    /// Makes file `index` A (B gives way when it was that file).
    mutating func setA(_ index: Int) {
        guard files.indices.contains(index) else { return }
        if index == b { b = a }
        a = index
    }

    /// Makes file `index` B.
    mutating func setB(_ index: Int) {
        guard files.indices.contains(index) else { return }
        if index == a { a = b }
        b = index
    }

    /// Replaces the file compared on one side.
    mutating func replace(sideA: Bool, with entry: ShelfEntry) {
        files[sideA ? a : b] = entry
    }

    /// Adds files at the end; with `makeB`, the first one becomes B.
    mutating func add(_ entries: [ShelfEntry], makeB: Bool) {
        let first = files.count
        files += entries
        if makeB, !entries.isEmpty { setB(first) }
    }

    /// Removes a file; refused while only two are left.
    @discardableResult
    mutating func remove(_ index: Int) -> Bool {
        guard files.count > 2, files.indices.contains(index) else { return false }
        files.remove(at: index)
        func shifted(_ i: Int) -> Int { i > index ? i - 1 : i }
        if index == a {
            a = shifted(b) == 0 ? 1 : 0
            b = shifted(b)
        } else if index == b {
            a = shifted(a)
            b = a == 0 ? 1 : 0
        } else {
            a = shifted(a)
            b = shifted(b)
        }
        return true
    }
}

/// The file shelf: a card per file (A or B letter, icon, name, folder and
/// an action menu), and at the right edge a column with "+" (add files),
/// "›" (next B) and "‹" (previous B).
@MainActor
final class FileShelfView: BarView {
    static let height: CGFloat = 75
    static let cardSize = NSSize(width: 240, height: 51)
    static let buttonColumnWidth: CGFloat = 31

    var onSetA: ((Int) -> Void)?
    var onSetB: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private let scroll = NSScrollView()
    private let strip = ShelfStripView()
    private(set) var cards: [FileShelfCard] = []
    let addButton: NSButton
    let nextButton: NSButton
    let previousButton: NSButton

    init() {
        func button(_ symbol: String, _ label: String, _ id: String) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                                  target: nil, action: nil)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = label
            button.setAccessibilityIdentifier(id)
            return button
        }
        addButton = button("plus", "Add Files", "prism.shelf.add")
        nextButton = button("chevron.right", "Next B (\u{2192})", "prism.shelf.next")
        previousButton = button("chevron.left", "Previous B (\u{2190})", "prism.shelf.previous")
        super.init(hairline: .bottom)
        scroll.documentView = strip
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        for (control, action) in [(addButton, #selector(addClicked(_:))), (nextButton, #selector(nextClicked(_:))),
                                  (previousButton, #selector(previousClicked(_:)))] {
            control.target = self
            control.action = action
            addSubview(control)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File Shelf")
        setAccessibilityIdentifier("prism.shelf")
    }

    func show(_ model: ShelfModel) {
        while cards.count > model.count { cards.removeLast().removeFromSuperview() }
        while cards.count < model.count {
            let card = FileShelfCard(shelf: self)
            cards.append(card)
            strip.addSubview(card)
        }
        for (index, entry) in model.files.enumerated() {
            let letter = index == model.a ? "A" : index == model.b ? "B" : ""
            cards[index].configure(entry, letter: letter, index: index, canRemove: model.count > 2)
        }
        nextButton.isEnabled = model.count > 2
        previousButton.isEnabled = model.count > 2
        needsLayout = true
    }

    func index(of card: FileShelfCard) -> Int? { cards.firstIndex { $0 === card } }

    override func layout() {
        super.layout()
        let column = Self.buttonColumnWidth
        scroll.frame = NSRect(x: 0, y: 0, width: max(bounds.width - column, 0), height: bounds.height - 1)
        let margin: CGFloat = 16, spacing: CGFloat = 12
        let size = Self.cardSize
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: margin + CGFloat(index) * (size.width + spacing),
                                y: floor((Self.height - 1 - size.height) / 2), width: size.width, height: size.height)
        }
        let width = margin * 2 + CGFloat(cards.count) * (size.width + spacing) - spacing
        strip.frame = NSRect(x: 0, y: 0, width: max(width, scroll.frame.width), height: scroll.frame.height)
        let x = bounds.width - column
        let heights: [CGFloat] = [24, 26, 25]
        var y: CGFloat = 0
        for (control, h) in zip([addButton, nextButton, previousButton], heights) {
            control.frame = NSRect(x: x, y: y, width: column, height: h)
            y += h
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSRect(x: bounds.width - Self.buttonColumnWidth, y: 0, width: 1, height: bounds.height).fill()
    }

    @objc private func addClicked(_ sender: Any?) { onAdd?() }
    @objc private func nextClicked(_ sender: Any?) { onNext?() }
    @objc private func previousClicked(_ sender: Any?) { onPrevious?() }

    /// Double-click on empty space adds files.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onAdd?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Shelf")
        menu.addItem(withTitle: "Add Files\u{2026}", action: #selector(addClicked(_:)), keyEquivalent: "").target = self
        return menu
    }
}

/// A file on the shelf.
@MainActor
final class FileShelfCard: NSView {
    private weak var shelf: FileShelfView?
    let letterField = NSTextField(labelWithString: "")
    let nameField = NSTextField(labelWithString: "")
    let pathField = NSTextField(labelWithString: "")
    let iconView = NSImageView()
    let actionButton: NSButton
    private(set) var entry: ShelfEntry?
    private var canRemove = false

    init(shelf: FileShelfView) {
        self.shelf = shelf
        actionButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Actions")!,
                                target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        letterField.font = .systemFont(ofSize: 17, weight: .regular)
        letterField.textColor = .controlAccentColor
        nameField.font = .systemFont(ofSize: 13)
        nameField.lineBreakMode = .byTruncatingMiddle
        pathField.font = .systemFont(ofSize: 11)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingHead
        actionButton.isBordered = false
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.target = self
        actionButton.action = #selector(actionClicked(_:))
        for view in [letterField, iconView, nameField, pathField, actionButton] as [NSView] { addSubview(view) }
        // The card itself is named after its file; the icon only decorates it.
        iconView.hideFromAccessibility()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ entry: ShelfEntry, letter: String, index: Int, canRemove: Bool) {
        self.entry = entry
        self.canRemove = canRemove
        letterField.stringValue = letter
        nameField.stringValue = entry.display == .nameOnly ? entry.url.lastPathComponent : entry.url.lastPathComponent
        pathField.stringValue = entry.display == .path
            ? (entry.url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            : "Clipboard"
        iconView.image = NSWorkspace.shared.icon(forFile: entry.url.path(percentEncoded: false))
        setAccessibilityLabel(entry.url.lastPathComponent)
        setAccessibilityValue(letter)
        setAccessibilityIdentifier("prism.shelf.card.\(index)")
        actionButton.setAccessibilityIdentifier("prism.shelf.card.\(index).actions")
        toolTip = entry.url.path(percentEncoded: false)
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        letterField.sizeToFit()
        letterField.frame.origin = NSPoint(x: 10, y: floor((h - letterField.frame.height) / 2))
        iconView.frame = NSRect(x: 30, y: floor((h - 32) / 2), width: 32, height: 32)
        actionButton.frame = NSRect(x: bounds.width - 30, y: floor((h - 20) / 2), width: 22, height: 20)
        let textX: CGFloat = 70, textWidth = max(bounds.width - textX - 34, 20)
        nameField.frame = NSRect(x: textX, y: 8, width: textWidth, height: 17)
        pathField.frame = NSRect(x: textX, y: 27, width: textWidth, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (letterField.stringValue.isEmpty ? NSColor.separatorColor : NSColor.controlAccentColor.withAlphaComponent(0.5))
            .setStroke()
        path.stroke()
    }

    /// A click makes the file B; with Option, A.
    override func mouseDown(with event: NSEvent) {
        guard let shelf, let index = shelf.index(of: self) else { return }
        if event.modifierFlags.contains(.option) { shelf.onSetA?(index) } else { shelf.onSetB?(index) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let shelf, let index = shelf.index(of: self) else { return false }
        shelf.onSetB?(index)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { actionMenu() }

    @objc private func actionClicked(_ sender: NSButton) {
        actionMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// Set as A / Set as B, Open With, Reveal in Finder, Copy Path, Remove.
    func actionMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        guard let entry else { return menu }
        func add(_ title: String, _ action: Selector?) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        add("Set as A", #selector(setA(_:)))
        add("Set as B", #selector(setB(_:)))
        menu.addItem(.separator())
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = FileActions.openWithMenu(for: entry.url)
        menu.addItem(openWith)
        add("Reveal in Finder", #selector(reveal(_:)))
        add("Copy Path", #selector(copyPath(_:)))
        menu.addItem(.separator())
        add("Remove", canRemove ? #selector(remove(_:)) : nil)
        return menu
    }

    @objc private func setA(_ sender: Any?) {
        guard let shelf, let index = shelf.index(of: self) else { return }
        shelf.onSetA?(index)
    }

    @objc private func setB(_ sender: Any?) {
        guard let shelf, let index = shelf.index(of: self) else { return }
        shelf.onSetB?(index)
    }

    @objc private func remove(_ sender: Any?) {
        guard let shelf, let index = shelf.index(of: self) else { return }
        shelf.onRemove?(index)
    }

    @objc private func reveal(_ sender: Any?) {
        if let entry { FileActions.reveal(entry.url) }
    }

    @objc private func copyPath(_ sender: Any?) {
        if let entry { FileActions.copyPath(entry.url) }
    }
}

/// Finder-style actions shared by the shelf and the path bar.
@MainActor
enum FileActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyPath(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(url.path(percentEncoded: false), forType: .string)
    }

    /// Opens a folder in Terminal.
    static func openInTerminal(_ url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Default (App)", the other apps that open the file, and Other….
    static func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu(title: "Open With")
        let target = OpenWithTarget.shared
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        func add(_ app: URL, title: String) {
            let item = menu.addItem(withTitle: title, action: #selector(OpenWithTarget.open(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = [url, app]
            let icon = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if let preferred {
            add(preferred, title: "\(appName(preferred)) (default)")
            menu.addItem(.separator())
        }
        for app in apps.prefix(20) where app != preferred { add(app, title: appName(app)) }
        if !apps.isEmpty { menu.addItem(.separator()) }
        let other = menu.addItem(withTitle: "Other\u{2026}", action: #selector(OpenWithTarget.chooseOther(_:)),
                                 keyEquivalent: "")
        other.target = target
        other.representedObject = url
        return menu
    }

    private static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }
}

@MainActor
final class OpenWithTarget: NSObject {
    static let shared = OpenWithTarget()

    @objc func open(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1], configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func chooseOther(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The scrolling row of cards (top-left origin).
@MainActor
final class ShelfStripView: NSView {
    override var isFlipped: Bool { true }
}
