// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismIntegration
import PrismProtocol

/// The rows of a changeset sidebar: a group row per folder ("Root Path" for
/// files at the top level, first), then that folder's files in the order
/// they arrived. A collapsed group shows no files.
struct ChangesetRows: Equatable {
    enum Row: Equatable {
        case group(String)
        /// Index into the changeset's entries.
        case file(Int)
    }

    static let rootTitle = "Root Path"

    private(set) var rows: [Row] = []
    /// Entries in display order, collapsed groups included.
    private(set) var entryOrder: [Int] = []
    private var groupOfEntry: [Int: String] = [:]

    init(relativePaths: [String], collapsed: Set<String> = []) {
        var folders: [String: [Int]] = [:]
        for (index, path) in relativePaths.enumerated() {
            folders[Self.folder(of: path), default: []].append(index)
        }
        let order = folders.keys.sorted { lhs, rhs in
            lhs.isEmpty != rhs.isEmpty ? lhs.isEmpty : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        for folder in order {
            let title = folder.isEmpty ? Self.rootTitle : folder
            let files = folders[folder, default: []]
            rows.append(.group(title))
            if !collapsed.contains(title) { rows += files.map(Row.file) }
            entryOrder += files
            for index in files { groupOfEntry[index] = title }
        }
    }

    static func folder(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder == "." ? "" : folder
    }

    /// The row showing entry `index`, nil when its group is collapsed.
    func row(ofEntry index: Int) -> Int? {
        rows.firstIndex(of: .file(index))
    }

    /// The title of the group holding entry `index`.
    func group(ofEntry index: Int) -> String? {
        groupOfEntry[index]
    }
}

/// The left side of a changeset window: a header with the version-control
/// tool's icon and "N changed files" (with a spinner while files may still
/// arrive), above a source list of the files with their status, grouped by
/// folder. Clicking a folder row collapses or expands it.
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
    /// Titles of the collapsed groups.
    private(set) var collapsedGroups: Set<String> = []
    /// The selected entry; it stays selected while its group is collapsed.
    private(set) var selectedEntry: Int?
    private var reloading = false
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
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
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
        self.entries = entries
        countLabel.stringValue = Self.countText(entries.count)
        reloadRows()
        needsLayout = true
    }

    /// Rebuilds the rows, keeping the selection without reporting it.
    private func reloadRows() {
        rows = ChangesetRows(relativePaths: entries.map(\.relativePath), collapsed: collapsedGroups)
        reloading = true
        defer { reloading = false }
        tableView.reloadData()
        if let selectedEntry, let row = rows.row(ofEntry: selectedEntry) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    func isCollapsed(_ group: String) -> Bool { collapsedGroups.contains(group) }

    func setCollapsed(_ collapsed: Bool, group: String) {
        guard collapsed != isCollapsed(group) else { return }
        if collapsed { collapsedGroups.insert(group) } else { collapsedGroups.remove(group) }
        reloadRows()
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.rows.count, case .group(let title) = rows.rows[row] else { return }
        setCollapsed(!isCollapsed(title), group: title)
    }

    func setReceiving(_ receiving: Bool) {
        if receiving { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.toolTip = receiving ? "More files may arrive" : nil
    }

    /// Selects entry `index`, expanding its group when collapsed.
    func selectEntry(_ index: Int) {
        if let group = rows.group(ofEntry: index) { setCollapsed(false, group: group) }
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
            return groupView(title)
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

    /// A folder row: a disclosure chevron and a folder icon, open or closed,
    /// before the folder's path.
    private func groupView(_ title: String) -> NSView {
        let collapsed = isCollapsed(title)
        let cell = NSTableCellView()
        let chevron = NSImageView(image: NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                                 accessibilityDescription: nil) ?? NSImage())
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        let folder = NSImageView(image: NSImage(systemSymbolName: collapsed ? "folder.fill" : "folder",
                                                accessibilityDescription: nil) ?? NSImage())
        folder.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        folder.contentTintColor = .secondaryLabelColor
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingHead
        field.toolTip = title
        for view in [chevron, folder, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.textField = field
        cell.setAccessibilityLabel("\(title), folder, \(collapsed ? "collapsed" : "expanded")")
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            folder.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            folder.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            folder.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: folder.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Keeps a file selected: clicks on empty space do not clear it.
    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.isEmpty && !reloading ? tableView.selectedRowIndexes : proposed
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.rows.count, case .file(let index) = rows.rows[row] else { return }
        selectedEntry = index
        onSelect?(index)
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
