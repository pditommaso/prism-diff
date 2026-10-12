// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismIntegration
import PrismProtocol

/// The rows of a changeset sidebar: a group row per folder ("Root Path" for
/// files at the top level, first), then that folder's files in the order
/// they arrived.
struct ChangesetRows: Equatable {
    enum Row: Equatable {
        case group(String)
        /// Index into the changeset's entries.
        case file(Int)
    }

    static let rootTitle = "Root Path"

    private(set) var rows: [Row] = []

    init(relativePaths: [String]) {
        var folders: [String: [Int]] = [:]
        for (index, path) in relativePaths.enumerated() {
            folders[Self.folder(of: path), default: []].append(index)
        }
        let order = folders.keys.sorted { lhs, rhs in
            lhs.isEmpty != rhs.isEmpty ? lhs.isEmpty : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for folder in order {
            rows.append(.group(folder.isEmpty ? Self.rootTitle : folder))
            rows += folders[folder, default: []].map(Row.file)
        }
    }

    static func folder(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder == "." ? "" : folder
    }

    /// The row showing entry `index`.
    func row(ofEntry index: Int) -> Int? {
        rows.firstIndex(of: .file(index))
    }

    /// Entries in display order.
    var entryOrder: [Int] {
        rows.compactMap { if case .file(let index) = $0 { index } else { nil } }
    }
}

/// The left side of a changeset window: a header with the version-control
/// tool's icon and "N changed files" (with a spinner while files may still
/// arrive), above a source list of the files with their status.
@MainActor
final class ChangesetSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let header = BarView(hairline: .bottom)
    let countLabel = NSTextField(labelWithString: "")
    let toolIcon = NSImageView()
    let spinner = NSProgressIndicator()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let background = NSVisualEffectView()

    private(set) var entries: [ChangesetEntry] = []
    private(set) var rows = ChangesetRows(relativePaths: [])
    /// Called with the entry index when the user selects a file.
    var onSelect: ((Int) -> Void)?

    init(tool: VersionControlTool) {
        super.init(frame: .zero)
        background.material = .sidebar
        background.blendingMode = .behindWindow
        addSubview(background)

        toolIcon.image = NSImage(systemSymbolName: Self.symbol(for: tool), accessibilityDescription: Self.toolName(tool))
        toolIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        toolIcon.contentTintColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        countLabel.setAccessibilityIdentifier("prism.changeset.count")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [toolIcon, countLabel, spinner] as [NSView] { header.addSubview(view) }
        addSubview(header)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.floatsGroupRows = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = false
        tableView.setAccessibilityIdentifier("prism.changeset.files")
        tableView.setAccessibilityLabel("Changed files")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        tableView.backgroundColor = .clear
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    static func symbol(for tool: VersionControlTool) -> String {
        switch tool {
        case .git, .mercurial, .bazaar: "arrow.triangle.branch"
        case .subversion, .perforce: "externaldrive.connected.to.line.below"
        case .unknown: "terminal"
        }
    }

    static func toolName(_ tool: VersionControlTool) -> String {
        switch tool {
        case .git: "Git"
        case .mercurial: "Mercurial"
        case .subversion: "Subversion"
        case .perforce: "Perforce"
        case .bazaar: "Bazaar"
        case .unknown: "Command line"
        }
    }

    static func countText(_ count: Int) -> String {
        count == 1 ? "1 changed file" : "\(count) changed files"
    }

    func setEntries(_ entries: [ChangesetEntry]) {
        let selected = selectedEntry
        self.entries = entries
        rows = ChangesetRows(relativePaths: entries.map(\.relativePath))
        countLabel.stringValue = Self.countText(entries.count)
        tableView.reloadData()
        if let selected, let row = rows.row(ofEntry: selected) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        needsLayout = true
    }

    func setReceiving(_ receiving: Bool) {
        if receiving { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.toolTip = receiving ? "More files may arrive" : nil
    }

    /// The entry of the selected row.
    var selectedEntry: Int? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.rows.count, case .file(let index) = rows.rows[row] else { return nil }
        return index
    }

    func selectEntry(_ index: Int) {
        guard let row = rows.row(ofEntry: index) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Selects the file `offset` rows after (or before) the current one, in
    /// display order. Returns false at either end.
    @discardableResult
    func moveSelection(by offset: Int) -> Bool {
        let order = rows.entryOrder
        guard let current = selectedEntry, let position = order.firstIndex(of: current) else {
            if let first = order.first { selectEntry(first); return true }
            return false
        }
        let target = position + offset
        guard order.indices.contains(target) else { return false }
        selectEntry(order[target])
        return true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let headerHeight = ComparisonContentView.pathBarHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width - 1, height: headerHeight)
        let middle = floor((headerHeight - 1) / 2)
        toolIcon.frame = NSRect(x: 12, y: middle - 9, width: 18, height: 18)
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: 36, y: middle - floor(countLabel.frame.height / 2))
        spinner.frame = NSRect(x: bounds.width - 30, y: middle - 8, width: 16, height: 16)
        scrollView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width - 1, height: max(bounds.height - headerHeight, 0))
        tableView.tableColumns.first?.width = scrollView.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows.rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = rows.rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows.rows[row] {
        case .group(let title):
            let field = NSTextField(labelWithString: "\u{25CF} \(title)")
            let italic = NSFontManager.shared.convert(.systemFont(ofSize: NSFont.smallSystemFontSize + 1), toHaveTrait: .italicFontMask)
            field.font = italic
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingHead
            return field
        case .file(let index):
            let entry = entries[index]
            let cell = NSTableCellView()
            let icon = NSImageView(image: Self.statusImage(entry.status))
            let name = NSTextField(labelWithString: (entry.relativePath as NSString).lastPathComponent)
            name.lineBreakMode = .byTruncatingMiddle
            name.toolTip = "\(entry.relativePath) \u{2014} \(Self.statusName(entry.status))"
            icon.translatesAutoresizingMaskIntoConstraints = false
            name.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(name)
            cell.imageView = icon
            cell.textField = name
            cell.setAccessibilityLabel("\(entry.relativePath), \(Self.statusName(entry.status))")
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let entry = selectedEntry { onSelect?(entry) }
    }

    static func statusName(_ status: FileStatus) -> String {
        switch status {
        case .changed: "changed"
        case .added: "added"
        case .removed: "removed"
        }
    }

    /// Status glyphs in the comparison colours: purple for a change, green
    /// for an addition, red for a removal.
    static func statusImage(_ status: FileStatus) -> NSImage {
        let (symbol, color): (String, NSColor) = switch status {
        case .changed: ("triangle", .systemPurple)
        case .added: ("plus.square", .systemGreen)
        case .removed: ("minus.square", .systemRed)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusName(status))?
            .withSymbolConfiguration(configuration) ?? NSImage()
        return image
    }
}
