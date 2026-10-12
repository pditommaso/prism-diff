// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import FolderCore

/// Where replaced items go. The Finder Trash, unless `PRISM_TRASH_DIR`
/// names a directory (acceptance runs, so they never fill the real Trash).
enum FolderTrash {
    static let environmentKey = "PRISM_TRASH_DIR"

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> any TrashMover {
        if let directory = environment[environmentKey], !directory.isEmpty {
            return DirectoryTrash(directory: directory)
        }
        return SystemTrash()
    }
}

/// Runs one copy on a background thread and reports to the main thread:
/// progress (coalesced), errors (the worker waits for the answer) and the
/// outcome.
@MainActor
final class FolderCopyRunner {
    let copier: FolderCopier
    private let lease: CopyLock.Lease
    private(set) var progress: CopyProgress
    private(set) var isCancelling = false
    private let pending = PendingProgress()

    var onProgress: ((CopyProgress) -> Void)?
    /// Asked on the main thread; call the reply exactly once.
    var onError: ((CopyFailure, @escaping (CopyRecovery) -> Void) -> Void)?
    var onFinish: ((CopyOutcome) -> Void)?

    init(copier: FolderCopier, lease: CopyLock.Lease) {
        self.copier = copier
        self.lease = lease
        progress = CopyProgress(completedBytes: 0, totalBytes: 0, itemIndex: 0, itemCount: copier.items.count,
                                name: copier.items.first?.name ?? "", phase: .preparing)
    }

    func start() {
        let copier = self.copier, pending = self.pending
        Thread.detachNewThread { [weak self] in
            let outcome = copier.run(progress: { update in
                // Deliver at most one main-thread update at a time.
                if pending.set(update) {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let latest = pending.take() else { return }
                            self?.deliver(latest)
                        }
                    }
                }
            }, onError: { failure in
                let answer = RecoveryBox()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let onError = self.onError, !copier.isCancelled else {
                            answer.resolve(.stop)
                            return
                        }
                        onError(failure) { answer.resolve($0) }
                    }
                }
                return answer.wait()
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(outcome) }
            }
        }
    }

    func cancel() {
        isCancelling = true
        copier.cancel()
        onProgress?(progress)
    }

    private func deliver(_ update: CopyProgress) {
        progress = update
        onProgress?(update)
    }

    private func finish(_ outcome: CopyOutcome) {
        lease.release()
        if let last = pending.take() { progress = last }
        onFinish?(outcome)
    }
}

/// The newest progress value, handed from the worker to the main thread.
private final class PendingProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CopyProgress?

    /// Stores the update; true when the main thread must be woken.
    func set(_ update: CopyProgress) -> Bool {
        lock.withLock {
            let wake = value == nil
            value = update
            return wake
        }
    }

    func take() -> CopyProgress? {
        lock.withLock {
            defer { value = nil }
            return value
        }
    }
}

/// The worker's wait for the user's answer to an error.
private final class RecoveryBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value = CopyRecovery.stop
    private var resolved = false

    func resolve(_ recovery: CopyRecovery) {
        let first = lock.withLock {
            guard !resolved else { return false }
            resolved = true
            value = recovery
            return true
        }
        if first { semaphore.signal() }
    }

    func wait() -> CopyRecovery {
        semaphore.wait()
        return lock.withLock { value }
    }
}

// MARK: - Summary sheet

/// The sheet shown before copying: one line per staged item, under the A
/// and B folder names, what happens to it, and the buttons.
@MainActor
final class CopySummarySheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    let items: [StagedCopy]
    let table = NSTableView()
    let copyButton = NSButton(title: "Copy Files", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// "copies to B" for new items, "replaces in B" for existing ones.
    static func phrase(_ item: StagedCopy) -> String {
        let side = item.direction == .toRight ? "B" : "A"
        return item.replaces ? "replaces the one in \(side)" : "copies to \(side)"
    }

    static let warning = "Copies can\u{2019}t be undone. Replaced items go to the Trash."

    init(items: [StagedCopy], leftName: String, rightName: String) {
        self.items = items
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320), styleMask: [.titled, .docModalWindow],
                         backing: .buffered, defer: true)
        super.init()
        window.title = "Copy Files"
        window.setAccessibilityIdentifier("prism.copySummary")
        let content = NSView()
        window.contentView = content

        let header = NSGridView(views: [[Self.badge("A"), Self.label(leftName), Self.badge("B"), Self.label(rightName)]])
        header.column(at: 1).width = 230
        header.columnSpacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = ""
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        table.setAccessibilityIdentifier("prism.copySummary.table")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(labelWithString: Self.warning)
        note.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("prism.copySummary.cancel")
        copyButton.keyEquivalent = "\r"
        copyButton.setAccessibilityIdentifier("prism.copySummary.copy")
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        copyButton.target = self
        copyButton.action = #selector(confirm(_:))
        let buttons = NSStackView(views: [cancelButton, copyButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, scroll, note, buttons] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            note.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private static func badge(_ letter: String) -> NSTextField {
        let field = NSTextField(labelWithString: letter)
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        field.textColor = .controlAccentColor
        return field
    }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    private var completion: ((Bool) -> Void)?

    func present(on parent: NSWindow, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        parent.beginSheet(window)
    }

    @objc func confirm(_ sender: Any?) { end(true) }
    @objc func cancel(_ sender: Any?) { end(false) }

    private func end(_ confirmed: Bool) {
        window.sheetParent?.endSheet(window)
        let completion = self.completion
        self.completion = nil
        completion?(confirmed)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = SummaryRowView()
        cell.configure(item)
        return cell
    }
}

/// One summary line: an arrow-shaped band in the row's status colour,
/// pointing from the source column to the destination, with the item's
/// icon and name, and what will happen to it.
@MainActor
final class SummaryRowView: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let phrase = NSTextField(labelWithString: "")
    private var item: StagedCopy?

    override init(frame: NSRect) {
        super.init(frame: frame)
        phrase.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        for view in [icon, name, phrase] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: StagedCopy) {
        self.item = item
        name.stringValue = item.name
        phrase.stringValue = CopySummarySheet.phrase(item)
        icon.image = NSWorkspace.shared.icon(for: item.isDirectory ? .folder : .data)
        setAccessibilityLabel("\(item.name), \(phrase.stringValue)")
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let half = bounds.width / 2
        let toRight = item?.direction != .toLeft
        let start = toRight ? 6 : half + 14
        icon.frame = NSRect(x: start, y: (bounds.height - 16) / 2, width: 16, height: 16)
        phrase.sizeToFit()
        name.sizeToFit()
        let phraseX = toRight ? half - phrase.frame.width - 6 : bounds.width - phrase.frame.width - 10
        phrase.frame.origin = NSPoint(x: phraseX, y: (bounds.height - phrase.frame.height) / 2)
        name.frame = NSRect(x: start + 22, y: (bounds.height - name.frame.height) / 2,
                            width: max(0, phraseX - start - 30), height: name.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let half = bounds.width / 2, inset: CGFloat = 2, tip: CGFloat = 12
        let rect = bounds.insetBy(dx: 0, dy: inset)
        let path = NSBezierPath()
        if item.direction == .toRight {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: half, y: rect.minY))
            path.line(to: NSPoint(x: half + tip, y: rect.midY))
            path.line(to: NSPoint(x: half, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: half, y: rect.minY))
            path.line(to: NSPoint(x: half - tip, y: rect.midY))
            path.line(to: NSPoint(x: half, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }
        path.close()
        (FolderColors.background(item.status) ?? .controlBackgroundColor).setFill()
        path.fill()
        FolderColors.accent(item.status).setStroke()
        path.stroke()
    }
}

// MARK: - Gutter button

/// The centre-gutter button of a row: shows the staged direction as an
/// arrow, the possible ones while the pointer is over it, and cycles
/// through them when clicked.
@MainActor
final class StageButton: NSView {
    var allowed: [CopyDirection] = [] { didSet { update() } }
    var direction: CopyDirection? { didSet { update() } }
    var status: RowStatus = .unchanged { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy direction")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The accessibility value: what is staged.
    static func describe(_ direction: CopyDirection?) -> String {
        switch direction {
        case .toRight: return "Copies to the right"
        case .toLeft: return "Copies to the left"
        case nil: return "Not staged"
        }
    }

    private func update() {
        isHidden = allowed.isEmpty
        setAccessibilityValue(Self.describe(direction))
        setAccessibilityEnabled(!allowed.isEmpty)
        toolTip = allowed.isEmpty ? nil : "Click to choose whether this item is copied, and in which direction"
        setAccessibilityHelp(allowed.isEmpty ? nil : "Press to change whether this item is copied, and in which direction")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !allowed.isEmpty else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard !allowed.isEmpty else { return false }
        onPress?()
        return true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let direction {
            // A wide chevron across the gutter, pointing at the destination.
            let rect = bounds.insetBy(dx: 0, dy: 1)
            let tip: CGFloat = min(12, rect.height / 2 + 1)
            let path = NSBezierPath()
            if direction == .toRight {
                path.move(to: NSPoint(x: rect.minX, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX - tip, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                path.line(to: NSPoint(x: rect.maxX - tip, y: rect.maxY))
                path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            } else {
                path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: NSPoint(x: rect.minX + tip, y: rect.minY))
                path.line(to: NSPoint(x: rect.minX, y: rect.midY))
                path.line(to: NSPoint(x: rect.minX + tip, y: rect.maxY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            }
            path.close()
            FolderColors.accent(status).setFill()
            path.fill()
        } else if hovering {
            // Outlined hints for the possible directions.
            let colour = FolderColors.selected(status).withAlphaComponent(0.6)
            colour.setStroke()
            for (index, option) in allowed.enumerated() {
                let centreX = allowed.count == 1 ? bounds.midX : bounds.midX + (index == 0 ? 9 : -9)
                let path = NSBezierPath()
                let y = bounds.midY, size: CGFloat = 4
                let sign: CGFloat = option == .toRight ? 1 : -1
                path.move(to: NSPoint(x: centreX - sign * size, y: y - size * 1.5))
                path.line(to: NSPoint(x: centreX + sign * size, y: y))
                path.line(to: NSPoint(x: centreX - sign * size, y: y + size * 1.5))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
}
