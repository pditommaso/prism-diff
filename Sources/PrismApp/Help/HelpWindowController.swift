// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// Help > Prism Help: a search field and the list of topics on the left,
/// the selected topic's text on the right. Everything is reachable from
/// the keyboard (Tab goes search field, topics, text) and named for
/// VoiceOver.
@MainActor
final class HelpWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let topics: [HelpTopic]
    let searchField = NSSearchField()
    let topicList = NSTableView()
    let textView = NSTextView()
    /// Topics that match the search (all of them when it is empty).
    private(set) var shown: [HelpTopic]

    init(topics: [HelpTopic]) {
        self.topics = topics
        shown = topics
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Prism Help"
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("prism.help")
        window.setFrameAutosaveName("PrismHelp")
        super.init(window: window)
        window.contentView = makeContentView()
        window.autorecalculatesKeyViewLoop = true
        window.initialFirstResponder = topicList
        DisplayOptions.applyMotion(to: window)
        select(topicID: topics.first?.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on `topicID` (or where it was) and brings it forward.
    func present(topicID: String? = nil) {
        if let topicID {
            searchField.stringValue = ""
            filter("")
            select(topicID: topicID)
        }
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        AppFocus.activate()
    }

    /// The topic on screen.
    var selectedTopic: HelpTopic? {
        shown.indices.contains(topicList.selectedRow) ? shown[topicList.selectedRow] : nil
    }

    /// Selects a topic of the list and shows it.
    func select(topicID: String?) {
        guard let index = shown.firstIndex(where: { $0.id == topicID }) ?? (shown.isEmpty ? nil : 0) else {
            show(nil)
            return
        }
        topicList.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        topicList.scrollRowToVisible(index)
        show(shown[index])
    }

    /// Keeps the topics whose text holds every word of `query`.
    func filter(_ query: String) {
        let current = selectedTopic?.id
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        shown = trimmed.isEmpty ? topics : topics.filter { $0.matches(trimmed) }
        topicList.reloadData()
        select(topicID: current)
    }

    private func show(_ topic: HelpTopic?) {
        let text = topic.map(HelpBook.render)
            ?? NSAttributedString(string: "No help topic matches your search.",
                                  attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                               .foregroundColor: NSColor.secondaryLabelColor])
        textView.textStorage?.setAttributedString(text)
        textView.scrollToBeginningOfDocument(nil)
        textView.setAccessibilityLabel(topic.map { "Help: \($0.title)" } ?? "Help")
    }

    // MARK: views

    private func makeContentView() -> NSView {
        searchField.placeholderString = "Search Help"
        searchField.setAccessibilityLabel("Search Help")
        searchField.setAccessibilityIdentifier("prism.help.search")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topic"))
        column.title = "Topics"
        topicList.addTableColumn(column)
        topicList.headerView = nil
        topicList.style = .sourceList
        topicList.dataSource = self
        topicList.delegate = self
        topicList.setAccessibilityLabel("Help Topics")
        topicList.setAccessibilityIdentifier("prism.help.topics")
        let listScroll = NSScrollView()
        listScroll.documentView = topicList
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("prism.help.text")
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder

        let sidebar = NSView()
        for view in [searchField, listScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            listScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 230),
        ])

        let split = NSStackView(views: [sidebar, textScroll])
        split.orientation = .horizontal
        split.spacing = 0
        split.alignment = .top
        split.distribution = .fill
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        textScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebar.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        textScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        return split
    }

    @objc private func searchChanged(_ sender: NSSearchField) { filter(sender.stringValue) }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("prism.help.topic")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = shown[row].title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let topic = selectedTopic else { return }
        show(topic)
    }
}
