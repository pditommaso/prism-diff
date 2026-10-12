// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// The tab strip of a document window: equal-width tabs (scope icon,
/// title, file-count badge, close button on hover), a "+" button that adds
/// a tab, and an overflow button listing the tabs that do not fit. Tabs
/// are reordered by dragging along the strip and moved into a new window
/// by dragging them away from it. A single tab shows a centred title, like
/// a window title.
@MainActor
final class DocumentTabStrip: BarView {
    struct Tab: Equatable {
        var title: String
        var symbol: String
        var count: Int
    }

    /// Below this width tabs move into the overflow menu.
    static let minimumTabWidth: CGFloat = 130
    static let addButtonWidth: CGFloat = 30
    static let overflowButtonWidth: CGFloat = 26
    /// How far (points) a tab must be dragged away from the strip to leave
    /// the window.
    static let detachDistance: CGFloat = 28

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onAddFiles: (() -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    var onDetach: ((_ index: Int, _ screenPoint: NSPoint?) -> Void)?
    var onBadge: ((Int) -> Void)?

    private(set) var items: [DocumentTabItem] = []
    private(set) var tabs: [Tab] = []
    private(set) var selected = 0
    let addButton: NSButton
    let overflowButton: NSButton
    /// The tabs on screen; the others are in the overflow menu.
    private(set) var visibleRange: Range<Int> = 0..<0
    private var dragged: DocumentTabItem?

    init() {
        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")!,
                             target: nil, action: nil)
        overflowButton = NSButton(image: NSImage(systemSymbolName: "chevron.right.2",
                                                 accessibilityDescription: "More Tabs")!, target: nil, action: nil)
        super.init(hairline: .bottom)
        for button in [addButton, overflowButton] {
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .secondaryLabelColor
            addSubview(button)
        }
        addButton.toolTip = "Add Tab (\u{2318}T)"
        addButton.setAccessibilityIdentifier("prism.tab.add")
        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        overflowButton.toolTip = "More tabs"
        overflowButton.setAccessibilityIdentifier("prism.tab.overflow")
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked(_:))
        overflowButton.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Comparisons")
        setAccessibilityIdentifier("prism.tabs")
    }

    func setTabs(_ tabs: [Tab], selected: Int) {
        self.tabs = tabs
        self.selected = selected
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        while items.count < tabs.count {
            let item = DocumentTabItem(strip: self)
            items.append(item)
            addSubview(item, positioned: .below, relativeTo: addButton)
        }
        for (index, tab) in tabs.enumerated() {
            items[index].configure(tab, selected: index == selected, multiple: tabs.count > 1, index: index)
        }
        needsLayout = true
        needsDisplay = true
    }

    func index(of item: DocumentTabItem) -> Int? { items.firstIndex { $0 === item } }

    /// How many tabs fit in `width` (at least one) and whether the overflow
    /// button is needed.
    static func fitting(count: Int, width: CGFloat) -> (visible: Int, overflow: Bool) {
        let space = max(width - addButtonWidth, 0)
        if CGFloat(count) * minimumTabWidth <= space { return (count, false) }
        let visible = max(1, Int((space - overflowButtonWidth) / minimumTabWidth))
        return (min(visible, count), true)
    }

    /// The window of `visible` tabs shown: from the start, moved just
    /// enough to include the selected one.
    static func visibleRange(count: Int, visible: Int, selected: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let start = selected < visible ? 0 : min(selected - visible + 1, count - visible)
        return start..<(start + visible)
    }

    override func layout() {
        super.layout()
        let height = bounds.height - 1
        let fit = Self.fitting(count: items.count, width: bounds.width)
        visibleRange = Self.visibleRange(count: items.count, visible: fit.visible, selected: selected)
        overflowButton.isHidden = !fit.overflow
        let right = bounds.width - Self.addButtonWidth - (fit.overflow ? Self.overflowButtonWidth : 0)
        addButton.frame = NSRect(x: bounds.width - Self.addButtonWidth, y: floor((height - 18) / 2),
                                 width: Self.addButtonWidth, height: 18)
        overflowButton.frame = NSRect(x: right, y: floor((height - 16) / 2), width: Self.overflowButtonWidth, height: 16)
        let count = CGFloat(max(visibleRange.count, 1))
        let width = right / count
        for (index, item) in items.enumerated() {
            guard visibleRange.contains(index) else {
                item.isHidden = true
                continue
            }
            item.isHidden = false
            let slot = CGFloat(index - visibleRange.lowerBound)
            guard item !== dragged else { continue }
            item.frame = NSRect(x: floor(slot * width), y: 0, width: floor((slot + 1) * width) - floor(slot * width),
                                height: height)
            item.needsLayout = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The divider left of "+".
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - Self.addButtonWidth, y: 0, width: 1, height: bounds.height - 1).fill()
    }

    // MARK: buttons and menus

    @objc private func addClicked(_ sender: Any?) { onAdd?() }

    @objc private func overflowClicked(_ sender: NSButton) {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// The tabs that do not fit.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu(title: "More Tabs")
        for (index, tab) in tabs.enumerated() where !visibleRange.contains(index) {
            let item = menu.addItem(withTitle: tab.title, action: #selector(overflowChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        }
        return menu
    }

    @objc private func overflowChosen(_ sender: NSMenuItem) { onSelect?(sender.tag) }

    /// Right-click on the strip outside the tabs.
    override func menu(for event: NSEvent) -> NSMenu? { backgroundMenu() }

    func backgroundMenu() -> NSMenu {
        let menu = NSMenu(title: "Tabs")
        menu.addItem(withTitle: "New Tab", action: #selector(addClicked(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Files in New Tab\u{2026}", action: #selector(addFilesChosen(_:)),
                     keyEquivalent: "").target = self
        return menu
    }

    /// Right-click on a tab.
    func tabMenu(for index: Int) -> NSMenu {
        let menu = NSMenu(title: "Tab")
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        add("Close Tab", #selector(closeChosen(_:)))
        add("Close Other Tabs", #selector(closeOthersChosen(_:)), enabled: tabs.count > 1)
        add("Move Tab to New Window", #selector(detachChosen(_:)), enabled: tabs.count > 1)
        menu.addItem(.separator())
        add("New Tab", #selector(addClicked(_:)))
        add("Open Files in New Tab\u{2026}", #selector(addFilesChosen(_:)))
        return menu
    }

    @objc private func closeChosen(_ sender: NSMenuItem) { onClose?(sender.tag) }
    @objc private func closeOthersChosen(_ sender: NSMenuItem) { onCloseOthers?(sender.tag) }
    @objc private func detachChosen(_ sender: NSMenuItem) { onDetach?(sender.tag, nil) }
    @objc private func addFilesChosen(_ sender: Any?) { onAddFiles?() }

    // MARK: dragging

    func beginDrag(_ item: DocumentTabItem) {
        dragged = item
        item.removeFromSuperview()
        addSubview(item, positioned: .below, relativeTo: addButton)
    }

    /// The drag ended at `point` (strip coordinates; `screenPoint` on
    /// screen): far from the strip, the tab leaves the window; along it,
    /// it moves to the slot under its centre.
    func endDrag(_ item: DocumentTabItem, at point: NSPoint, screenPoint: NSPoint?) {
        dragged = nil
        guard let from = index(of: item) else { return needsLayout = true }
        if Self.isDetach(point: point, stripHeight: bounds.height), items.count > 1 {
            needsLayout = true
            onDetach?(from, screenPoint)
            return
        }
        let to = Self.dropIndex(centerX: item.frame.midX, visible: visibleRange, width: overflowButton.isHidden
                                    ? bounds.width - Self.addButtonWidth
                                    : bounds.width - Self.addButtonWidth - Self.overflowButtonWidth)
        needsLayout = true
        if to != from { onMove?(from, to) }
    }

    static func isDetach(point: NSPoint, stripHeight: CGFloat) -> Bool {
        point.y < -detachDistance || point.y > stripHeight + detachDistance
    }

    /// The tab index under `centerX` among the visible slots.
    static func dropIndex(centerX: CGFloat, visible: Range<Int>, width: CGFloat) -> Int {
        guard !visible.isEmpty, width > 0 else { return visible.lowerBound }
        let slot = Int(floor(centerX / (width / CGFloat(visible.count))))
        return visible.lowerBound + min(max(slot, 0), visible.count - 1)
    }
}

/// One tab: icon, title, badge and the close button that shows on hover.
@MainActor
final class DocumentTabItem: NSView {
    let titleField = NSTextField(labelWithString: "")
    let badge = NSButton(title: "2", target: nil, action: nil)
    let closeButton: NSButton
    private let icon = NSImageView()
    private weak var strip: DocumentTabStrip?
    private var selected = false
    private var multiple = false
    private var hovering = false { didSet { updateClose() } }
    private var tracking: NSTrackingArea?

    init(strip: DocumentTabStrip) {
        self.strip = strip
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!,
                               target: nil, action: nil)
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingMiddle
        badge.isBordered = false
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7.5
        badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        badge.toolTip = "Files in this comparison (click to show or hide the file shelf)"
        badge.target = self
        badge.action = #selector(badgeClicked(_:))
        closeButton.isBordered = false
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Tab (\u{2318}W)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.isHidden = true
        for view in [icon, titleField, badge, closeButton] as [NSView] { addSubview(view) }
        // The tab itself carries the title: its icon and title field would
        // only repeat it to VoiceOver.
        icon.hideFromAccessibility()
        titleField.hideFromAccessibility()
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ tab: DocumentTabStrip.Tab, selected: Bool, multiple: Bool, index: Int) {
        titleField.stringValue = tab.title
        icon.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        badge.title = String(tab.count)
        badge.isHidden = tab.count == 0
        self.selected = selected
        self.multiple = multiple
        titleField.textColor = selected || !multiple ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(selected ? 1 : 0)
        setAccessibilityIdentifier("prism.tab.\(index)")
        closeButton.setAccessibilityIdentifier("prism.tab.\(index).close")
        badge.setAccessibilityIdentifier("prism.tab.\(index).badge")
        badge.setAccessibleName(tab.count == 1 ? "1 file" : "\(tab.count) files", help: "Shows or hides the file shelf")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in self?.perform(\.onClose) ?? false },
            NSAccessibilityCustomAction(name: "Move Tab to New Window") { [weak self] in
                guard let self, let strip = self.strip, let at = strip.index(of: self), strip.items.count > 1
                else { return false }
                strip.onDetach?(at, nil)
                return true
            },
        ])
        updateClose()
        needsLayout = true
        needsDisplay = true
    }

    private func perform(_ path: KeyPath<DocumentTabStrip, ((Int) -> Void)?>) -> Bool {
        guard let strip, let at = strip.index(of: self), let action = strip[keyPath: path] else { return false }
        action(at)
        return true
    }

    private func updateClose() {
        closeButton.isHidden = !hovering
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    @objc private func closeClicked(_ sender: Any?) { _ = perform(\.onClose) }
    @objc private func badgeClicked(_ sender: Any?) { _ = perform(\.onBadge) }

    override func accessibilityPerformPress() -> Bool { perform(\.onSelect) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let strip, let at = strip.index(of: self) else { return nil }
        return strip.tabMenu(for: at)
    }

    /// A click selects; a drag along the strip reorders; a drag away from
    /// it moves the tab into a new window.
    override func mouseDown(with event: NSEvent) {
        guard let window, let strip else { return }
        let start = event.locationInWindow
        let originX = frame.minX
        var dragging = false
        var last = start
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            last = next.locationInWindow
            if next.type == .leftMouseUp { break }
            if !dragging, hypot(last.x - start.x, last.y - start.y) > 4, strip.items.count > 1 {
                dragging = true
                strip.beginDrag(self)
            }
            if dragging { frame.origin.x = originX + (last.x - start.x) }
        }
        guard dragging else {
            _ = perform(\.onSelect)
            return
        }
        let point = strip.convert(last, from: nil)
        let screen = window.convertPoint(toScreen: last)
        strip.endDrag(self, at: point, screenPoint: screen)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard multiple else { return }
        (selected ? NSColor.windowBackgroundColor : NSColor.underPageBackgroundColor).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func layout() {
        super.layout()
        titleField.sizeToFit()
        let height = bounds.height
        badge.sizeToFit()
        let badgeWidth = badge.isHidden ? 0 : max(badge.frame.width + 6, 18)
        let reserve = 28 + badgeWidth + 12
        let titleWidth = max(min(titleField.frame.width, bounds.width - 2 * reserve), 30)
        let total = 16 + 4 + titleWidth
        let x = max(floor((bounds.width - total) / 2), 26)
        icon.frame = NSRect(x: x, y: floor((height - 16) / 2), width: 16, height: 16)
        titleField.frame = NSRect(x: x + 20, y: floor((height - titleField.frame.height) / 2),
                                  width: min(titleWidth, max(bounds.width - x - 20 - badgeWidth - 16, 20)),
                                  height: titleField.frame.height)
        badge.frame = NSRect(x: bounds.width - badgeWidth - 10, y: floor((height - 15) / 2), width: badgeWidth, height: 15)
        closeButton.frame = NSRect(x: 6, y: floor((height - 16) / 2), width: 16, height: 16)
    }
}
