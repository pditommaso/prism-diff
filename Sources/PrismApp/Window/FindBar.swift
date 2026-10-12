// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore

/// The find bar, shown between the path bar and the text:
///
///     [🔍 query ⓧ] [A|B] [‹|›]  3rd of 9 results in A (2 more in B)   [Close]
@MainActor
final class FindBarView: BarView {
    static let height: CGFloat = 28

    let field = NSSearchField()
    let scopeControl = NSSegmentedControl(labels: ["A", "B"], trackingMode: .selectOne, target: nil, action: nil)
    let stepControl: NSSegmentedControl
    let summaryLabel = NSTextField(labelWithString: "")
    let noteButton = NSButton(title: "", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)

    init() {
        let images = zip(["chevron.left", "chevron.right"], ["Previous Match", "Next Match"]).map {
            NSImage(systemSymbolName: $0, accessibilityDescription: $1) ?? NSImage()
        }
        stepControl = NSSegmentedControl(images: images, trackingMode: .momentary, target: nil, action: nil)
        super.init(hairline: .bottom)
        field.placeholderString = "Find"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.setAccessibilityIdentifier("prism.find.field")
        field.setAccessibleName("Find")
        scopeControl.controlSize = .small
        scopeControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        scopeControl.selectedSegment = 0
        scopeControl.setToolTip("Search in A", forSegment: 0)
        scopeControl.setToolTip("Search in B", forSegment: 1)
        scopeControl.setAccessibilityIdentifier("prism.find.scope")
        scopeControl.setAccessibleName("Search In", help: "Chooses whether Find searches A or B")
        stepControl.controlSize = .small
        stepControl.setToolTip("Previous result (\u{21E7}\u{2318}G)", forSegment: 0)
        stepControl.setToolTip("Next result (\u{2318}G)", forSegment: 1)
        stepControl.setAccessibilityIdentifier("prism.find.step")
        stepControl.setAccessibleName("Matches")
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.setAccessibilityIdentifier("prism.find.summary")
        noteButton.isBordered = false
        noteButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteButton.setAccessibilityIdentifier("prism.find.other")
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        closeButton.setAccessibilityIdentifier("prism.find.close")
        for view in [field, scopeControl, stepControl, summaryLabel, noteButton, closeButton] as [NSView] {
            addSubview(view)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.blended(withFraction: 0.35, of: .windowBackgroundColor)?.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Shows the summary and the note (a link when it switches sides).
    func setSummary(_ text: String, note: String?, noteIsLink: Bool) {
        summaryLabel.stringValue = text
        noteButton.isHidden = note == nil
        noteButton.isEnabled = noteIsLink
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: noteIsLink ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .underlineStyle: noteIsLink ? NSUnderlineStyle.single.rawValue : 0,
        ]
        noteButton.attributedTitle = NSAttributedString(string: note ?? "", attributes: attributes)
        noteButton.setAccessibilityLabel(note)
        needsLayout = true
    }

    /// Shows or hides the A/B scope (Unified searches its single text).
    func setScopeVisible(_ visible: Bool) {
        scopeControl.isHidden = !visible
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height - 1
        func centre(_ view: NSView, x: CGFloat, width: CGFloat) {
            let h = view.fittingSize.height > 0 ? min(view.fittingSize.height, height) : 20
            view.frame = NSRect(x: x, y: floor((height - h) / 2), width: width, height: h)
        }
        var x: CGFloat = 8
        centre(field, x: x, width: 223)
        x += 223 + 12
        if !scopeControl.isHidden {
            scopeControl.sizeToFit()
            centre(scopeControl, x: x, width: max(scopeControl.frame.width, 64))
            x = scopeControl.frame.maxX + 10
        }
        stepControl.sizeToFit()
        centre(stepControl, x: x, width: stepControl.frame.width)
        x = stepControl.frame.maxX + 12
        closeButton.sizeToFit()
        let closeX = bounds.width - closeButton.frame.width - 8
        centre(closeButton, x: closeX, width: closeButton.frame.width)
        summaryLabel.sizeToFit()
        centre(summaryLabel, x: x, width: min(summaryLabel.frame.width, max(closeX - x - 8, 0)))
        x = summaryLabel.frame.maxX + 4
        noteButton.sizeToFit()
        centre(noteButton, x: x, width: min(noteButton.frame.width, max(closeX - x - 8, 0)))
    }
}

/// Runs searches for one comparison window and keeps the find bar, the
/// highlights and the current match in step.
@MainActor
final class FindController: NSObject, NSSearchFieldDelegate {
    let bar = FindBarView()
    private weak var view: BlocksDiffView?
    /// Called when the bar should be shown or hidden.
    var onVisibilityChange: ((Bool) -> Void)?

    private(set) var isVisible = false
    private(set) var query = ""
    /// The side searched in Blocks and Fluid.
    private(set) var scope: DiffSide = .a
    private(set) var results: [DiffSide: [FindMatch]] = [:]
    /// What ‹ › step through: the scope side, or the unified text.
    private(set) var active: [FindMatch] = []
    private(set) var current: Int?
    private var generation = 0
    private var searchFlag: CancellationFlag?
    /// Matches of `active` by side and line, built once per result set.
    private var lineMap: [DiffSide: [Int: [Range<Int>]]] = [:]
    private var lineMapID = 0
    /// True while a search runs in the background.
    private(set) var isSearching = false

    init(view: BlocksDiffView) {
        self.view = view
        super.init()
        bar.field.delegate = self
        bar.field.target = self
        bar.field.action = #selector(fieldChanged(_:))
        bar.scopeControl.target = self
        bar.scopeControl.action = #selector(scopeChanged(_:))
        bar.stepControl.target = self
        bar.stepControl.action = #selector(stepped(_:))
        bar.noteButton.target = self
        bar.noteButton.action = #selector(switchSides(_:))
        bar.closeButton.target = self
        bar.closeButton.action = #selector(close(_:))
        refreshBar()
    }

    // MARK: commands

    /// ⌘F: shows the bar and focuses the field.
    func show() {
        if !isVisible {
            isVisible = true
            onVisibilityChange?(true)
        }
        bar.setScopeVisible(view?.mode != .unified)
        bar.window?.makeFirstResponder(bar.field)
        applyHighlights()
    }

    /// Close and Esc.
    @objc func close(_ sender: Any?) {
        guard isVisible else { return }
        isVisible = false
        onVisibilityChange?(false)
        applyHighlights()
        if let view { view.window?.makeFirstResponder(view.textPane(view.selectionPane)) }
    }

    /// Searches for `text` (Use Selection for Find, tests).
    func find(_ text: String) {
        bar.field.stringValue = text
        setQuery(text)
    }

    func next() { step(1) }
    func previous() { step(-1) }

    /// Re-runs the search after the comparison changed.
    func refresh() {
        bar.setScopeVisible(view?.mode != .unified)
        if query.isEmpty {
            rebuildActive(keepCurrent: false)
        } else {
            run()
        }
    }

    func setScope(_ side: DiffSide) {
        guard side != scope else { return }
        scope = side
        bar.scopeControl.selectedSegment = side == .a ? 0 : 1
        rebuildActive(keepCurrent: false)
        revealCurrent()
    }

    // MARK: actions

    @objc private func fieldChanged(_ sender: NSSearchField) {
        setQuery(sender.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        setQuery(bar.field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close(nil)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { next() }
            return true
        default:
            return false
        }
    }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        setScope(sender.selectedSegment == 1 ? .b : .a)
    }

    @objc private func stepped(_ sender: NSSegmentedControl) {
        step(sender.selectedSegment == 0 ? -1 : 1)
    }

    @objc private func switchSides(_ sender: Any?) {
        setScope(scope == .a ? .b : .a)
    }

    // MARK: searching

    private func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        run()
    }

    private func run() {
        searchFlag?.cancel()
        searchFlag = nil
        generation += 1
        let current = generation
        guard let model = view?.model, !query.isEmpty else {
            results = [:]
            isSearching = false
            rebuildActive(keepCurrent: false)
            return
        }
        isSearching = true
        let query = self.query
        let a = model.a, b = model.b
        let flag = CancellationFlag()
        searchFlag = flag
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> [DiffSide: [FindMatch]] in
                [.a: FindEngine.search(a, side: .a, query: query, cancelled: { flag.isCancelled }),
                 .b: FindEngine.search(b, side: .b, query: query, cancelled: { flag.isCancelled })]
            }.value
            guard let self else { return }
            guard self.generation == current else { return }
            self.isSearching = false
            self.results = found
            self.rebuildActive(keepCurrent: false)
            self.revealCurrent()
        }
    }

    /// Builds the list ‹ › walks and picks the current match: the first
    /// one at or below the top of the visible text.
    private func rebuildActive(keepCurrent: Bool) {
        guard let view else { return }
        if view.mode == .unified, let geometry = view.geometryA, let model = view.model {
            // The unified text shows unchanged lines once, as A.
            let fromB = (results[.b] ?? []).filter { match in
                model.layout.block(ofLine: match.line, side: .b).map { model.layout.blocks[$0].kind != .equal } ?? false
            }
            let rows = (results[.a] ?? []) + fromB
            let placed: [(match: FindMatch, row: Int)] = rows.map { match in
                (match, geometry.rows.row(ofLine: match.line, side: match.side) ?? 0)
            }
            let ordered = placed.sorted { lhs, rhs in
                if lhs.row != rhs.row { return lhs.row < rhs.row }
                return lhs.match.range.lowerBound < rhs.match.range.lowerBound
            }
            active = ordered.map(\.match)
        } else {
            active = results[scope] ?? []
        }
        var map: [DiffSide: [Int: [Range<Int>]]] = [:]
        for match in active {
            map[match.side, default: [:]][match.line, default: []].append(match.range)
        }
        lineMap = map
        lineMapID += 1
        if !keepCurrent || current.map({ $0 >= active.count }) ?? true {
            current = active.isEmpty ? nil : firstVisibleIndex()
        }
        refreshBar()
        applyHighlights()
    }

    private func firstVisibleIndex() -> Int {
        guard let view else { return 0 }
        let pane: DiffSide = view.mode == .unified ? .a : scope
        guard let geometry = view.geometry(for: pane) else { return 0 }
        let topRow = geometry.row(atY: view.scrollY(of: pane) + view.metrics.topInset)
        for (index, match) in active.enumerated() {
            let row = view.mode == .blocks ? view.model?.layout.row(ofLine: match.line, side: match.side)
                                           : geometry.rows.row(ofLine: match.line, side: match.side)
            if let row, row >= topRow { return index }
        }
        return 0
    }

    private func step(_ delta: Int) {
        guard !active.isEmpty else {
            if !isVisible { show() }
            return
        }
        let count = active.count
        current = ((current ?? (delta > 0 ? -1 : 0)) + delta + count) % count
        refreshBar()
        applyHighlights()
        revealCurrent()
    }

    private func revealCurrent() {
        guard let current, current < active.count, isVisible else { return }
        view?.reveal(active[current])
    }

    // MARK: display

    var summary: String { bar.summaryLabel.stringValue }
    var note: String? { bar.noteButton.isHidden ? nil : bar.noteButton.title }

    private func refreshBar() {
        guard !query.isEmpty else {
            bar.setSummary("", note: nil, noteIsLink: false)
            return
        }
        let unified = view?.mode == .unified
        let other = unified ? 0 : results[scope == .a ? .b : .a]?.count ?? 0
        let (text, note) = FindEngine.summary(count: active.count, current: current,
                                              scope: unified ? nil : scope, other: other)
        bar.setSummary(text, note: note, noteIsLink: other > 0)
        if PerfLog.isEnabled {
            PerfLog.record("find", ["query": query, "summary": text, "note": note ?? ""])
        }
    }

    private func applyHighlights() {
        guard let view else { return }
        guard isVisible, !query.isEmpty else {
            view.findHighlights = FindHighlights()
            return
        }
        // The same line map (and id) as long as the results stand, so a
        // step redraws only the old and new current match.
        view.findHighlights = FindHighlights(lines: lineMap, current: current.map { active[$0] }, dims: true,
                                             id: lineMapID)
    }
}
