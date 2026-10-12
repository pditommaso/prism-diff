// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// One side's location in the path bar: a capsule of path components. The
/// volume and the folders in the middle show as bare icons; the last two
/// components (the folder and the file) show their name and a ⌄. When even
/// that does not fit, the leading components collapse into "»". Every
/// component pops up a menu: its siblings (choosing one compares it
/// instead), then Reveal in Finder, Copy Path, and Open in Terminal (a
/// folder) or Open With (a file).
@MainActor
final class BreadcrumbView: NSView {
    /// How many trailing components keep their name.
    static let namedComponents = 2
    static let iconWidth: CGFloat = 22
    static let separatorWidth: CGFloat = 10
    static let height: CGFloat = 20

    /// A sibling (or a component's relative path under a sibling) chosen.
    var onChoose: ((URL) -> Void)?

    private(set) var components: [URL] = []
    private(set) var buttons: [NSButton] = []
    private var separators: [NSImageView] = []
    private let overflow = NSButton(title: "\u{00BB}", target: nil, action: nil)
    /// Leading components folded into "»".
    private(set) var collapsed = 0
    private var display: PathBarView.Display = .path
    private var shownURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        overflow.isBordered = false
        overflow.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        overflow.target = self
        overflow.action = #selector(overflowClicked(_:))
        overflow.isHidden = true
        overflow.setAccessibleName("Hidden folders")
        addSubview(overflow)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The components from the volume down to `url`: "/" is the startup
    /// volume; a path under /Volumes starts at that volume.
    static func components(of url: URL) -> [URL] {
        var parts: [URL] = []
        var current = url.standardizedFileURL
        while current.path(percentEncoded: false) != "/" {
            parts.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == "/Volumes/" || parent.path(percentEncoded: false) == "/Volumes" {
                return parts.reversed()
            }
            if parent == current { break }
            current = parent
        }
        parts.append(URL(filePath: "/", directoryHint: .isDirectory))
        return parts.reversed()
    }

    /// The title of a component: the volume's name for the root.
    static func name(of url: URL) -> String {
        if url.path(percentEncoded: false) == "/" {
            return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "/"
        }
        return url.lastPathComponent
    }

    func show(_ url: URL, display: PathBarView.Display) {
        guard url != shownURL || display != self.display else { return }
        shownURL = url
        self.display = display
        for button in buttons { button.removeFromSuperview() }
        for separator in separators { separator.removeFromSuperview() }
        buttons = []
        separators = []
        switch display {
        case .path:
            components = Self.components(of: url)
        case .nameOnly, .absent:
            components = [url]
        }
        for (index, component) in components.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(componentClicked(_:)))
            button.isBordered = false
            button.tag = index
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel(display == .absent ? "No file" : Self.name(of: component))
            button.toolTip = component.path(percentEncoded: false)
            buttons.append(button)
            addSubview(button)
            if index > 0 {
                let separator = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right",
                                                           accessibilityDescription: nil) ?? NSImage())
                separator.contentTintColor = .tertiaryLabelColor
                // Decoration: VoiceOver reads the components, not the chevrons.
                separator.hideFromAccessibility()
                separators.append(separator)
                addSubview(separator)
            }
        }
        setAccessibilityLabel(display == .absent ? "No file" : url.path(percentEncoded: false))
        needsLayout = true
        needsDisplay = true
    }

    /// Named titles shown (for tests): "" for icon-only components.
    var shownTitles: [String] { buttons.filter { !$0.isHidden }.map(\.title) }

    private func configure(_ button: NSButton, named: Bool) {
        let index = button.tag
        let url = components[index]
        let image: NSImage?
        if display != .path {
            image = NSImage(systemSymbolName: display == .absent ? "doc.badge.ellipsis" : "doc.on.clipboard",
                            accessibilityDescription: nil)
        } else if index == 0 {
            image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        } else if index == components.count - 1, !AppDelegate.isDirectory(url) {
            image = nil
        } else {
            image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        }
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = .secondaryLabelColor
        if named || display != .path {
            let name = display == .absent ? "No file" : Self.name(of: url)
            button.title = display == .path ? name + " \u{2304}" : name
            button.imagePosition = image == nil ? .noImage : .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        // Setting the image replaces the button's label with the symbol's
        // own description; name the component again.
        button.setAccessibleName(display == .absent ? "No file" : Self.name(of: url),
                                 help: display == .path ? "Shows the items next to \(Self.name(of: url))" : nil)
    }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let named = Set(max(0, buttons.count - Self.namedComponents)..<buttons.count)
        for button in buttons { configure(button, named: named.contains(button.tag)) }
        func width(_ button: NSButton) -> CGFloat {
            button.imagePosition == .imageOnly ? Self.iconWidth : ceil(button.intrinsicContentSize.width) + 4
        }
        let available = bounds.width - 12
        // Fold leading components (after the volume) until the rest fits.
        collapsed = 0
        func total() -> CGFloat {
            let shown = buttons.dropFirst(collapsed)
            var sum = shown.reduce(0) { $0 + width($1) } + CGFloat(max(shown.count - 1, 0)) * Self.separatorWidth
            if collapsed > 0 { sum += Self.iconWidth + Self.separatorWidth }
            return sum
        }
        while total() > available, collapsed < buttons.count - 1 { collapsed += 1 }
        overflow.isHidden = collapsed == 0
        var x: CGFloat = 6
        let y = floor((bounds.height - Self.height) / 2)
        if collapsed > 0 {
            overflow.frame = NSRect(x: x, y: y, width: Self.iconWidth, height: Self.height)
            x += Self.iconWidth
        }
        for (index, button) in buttons.enumerated() {
            let hidden = index < collapsed
            button.isHidden = hidden
            if index > 0 { separators[index - 1].isHidden = hidden }
            guard !hidden else { continue }
            if index > 0 {
                separators[index - 1].frame = NSRect(x: x, y: y + 4, width: Self.separatorWidth, height: 12)
                x += Self.separatorWidth
            }
            let w = min(width(button), max(bounds.width - x - 6, 20))
            button.frame = NSRect(x: x, y: y, width: w, height: Self.height)
            x += w
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !buttons.isEmpty else { return }
        let lastMaxX = buttons.last { !$0.isHidden }?.frame.maxX ?? 0
        let capsule = NSRect(x: 0.5, y: floor((bounds.height - Self.height) / 2) + 0.5,
                             width: min(lastMaxX + 6, bounds.width - 1), height: Self.height - 1)
        let path = NSBezierPath(roundedRect: capsule, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    // MARK: menus

    @objc private func componentClicked(_ sender: NSButton) {
        menu(forComponent: sender.tag).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        let menu = NSMenu(title: "Folders")
        for index in 0..<collapsed {
            let item = NSMenuItem(title: Self.name(of: components[index]), action: nil, keyEquivalent: "")
            item.submenu = self.menu(forComponent: index)
            item.image = NSImage(systemSymbolName: index == 0 ? "internaldrive" : "folder.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// The siblings of a component, sorted by name (hidden items left
    /// out), at most `limit`.
    static func siblings(of url: URL, limit: Int = 200) -> [URL] {
        let parent = url.deletingLastPathComponent()
        guard url.path(percentEncoded: false) != "/",
              let items = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return Array(items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit))
    }

    /// The path under component `index`, to look for under a sibling.
    func remainder(after index: Int) -> [String] {
        components.dropFirst(index + 1).map(\.lastPathComponent)
    }

    func menu(forComponent index: Int) -> NSMenu {
        let menu = NSMenu(title: "Path")
        guard components.indices.contains(index) else { return menu }
        let url = components[index]
        let target = BreadcrumbMenuTarget.shared
        if display == .path {
            let rest = remainder(after: index)
            for sibling in Self.siblings(of: url) {
                let item = menu.addItem(withTitle: sibling.lastPathComponent,
                                        action: #selector(BreadcrumbMenuTarget.choose(_:)), keyEquivalent: "")
                item.target = target
                var chosen = sibling
                for part in rest { chosen.append(path: part) }
                item.representedObject = BreadcrumbChoice(view: self, url: chosen)
                let icon = NSWorkspace.shared.icon(forFile: sibling.path(percentEncoded: false))
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                if sibling.standardizedFileURL == url.standardizedFileURL { item.state = .on }
                // A sibling without the same file or folder below it
                // cannot replace this side.
                if !rest.isEmpty, !FileManager.default.fileExists(atPath: chosen.path(percentEncoded: false)) {
                    item.action = nil
                }
            }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        }
        guard display != .absent else { return menu }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = url
        }
        add("Reveal in Finder", #selector(BreadcrumbMenuTarget.reveal(_:)))
        add("Copy Path", #selector(BreadcrumbMenuTarget.copyPath(_:)))
        if AppDelegate.isDirectory(url) {
            add("Open in Terminal", #selector(BreadcrumbMenuTarget.openInTerminal(_:)))
        } else {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = FileActions.openWithMenu(for: url)
            menu.addItem(openWith)
        }
        return menu
    }
}

/// A sibling chosen in a breadcrumb menu.
@MainActor
final class BreadcrumbChoice: NSObject {
    weak var view: BreadcrumbView?
    let url: URL

    init(view: BreadcrumbView, url: URL) {
        self.view = view
        self.url = url
    }
}

@MainActor
final class BreadcrumbMenuTarget: NSObject {
    static let shared = BreadcrumbMenuTarget()

    @objc func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? BreadcrumbChoice else { return }
        choice.view?.onChoose?(choice.url)
    }

    @objc func reveal(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { FileActions.reveal(url) }
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { FileActions.copyPath(url) }
    }

    @objc func openInTerminal(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { FileActions.openInTerminal(url) }
    }
}
