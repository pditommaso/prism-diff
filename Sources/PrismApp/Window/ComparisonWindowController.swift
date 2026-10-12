// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import AVFoundation
import DiffCore
import os
import PrismProtocol

/// A window comparing two text files, in Blocks, Fluid or Unified layout.
///
/// Reading the files and running the diff happen off the main thread; the
/// window appears at once and shows a "Comparing…" placeholder if the work
/// takes longer than 150 ms. Closing the window cancels a running diff.
@MainActor
class ComparisonWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let defaultFrameSize = NSSize(width: 1354, height: 908)
    static let minimumContentSize = NSSize(width: 612, height: 443)
    /// How long a load may run before the placeholder appears.
    static let placeholderDelay: Duration = .milliseconds(150)

    private(set) var urlA: URL
    private(set) var urlB: URL
    let blocksView: BlocksDiffView
    let tabStrip = TabStripView()
    let pathBar: PathBarView
    let bottomBar: BottomBarView
    let placeholder = PlaceholderView()
    let find: FindController
    let content = ComparisonContentView()

    /// Called when the window has closed.
    var onClose: ((ComparisonWindowController) -> Void)?
    /// Called after the layout changed (a document window records its
    /// tabs' layouts).
    var onModeChange: (() -> Void)?

    var texts: (a: LoadedText, b: LoadedText)?
    /// Edits, merges, undo and saving (see ComparisonWindowController+Editing).
    let session: EditSession
    /// The swapped-in editor over the block being edited.
    private(set) lazy var editor = BlockEditor(host: blocksView)
    /// The running load re-reads the files (rather than re-diffing edits).
    private var loadRereads = false
    /// The running load re-diffs an edit: no placeholder, no blank stepper.
    var quietLoad = false
    /// When the last edit was handed to the session (0: none pending).
    var editStarted: UInt64 = 0
    /// The last refused edit, merge or save (also shown as a sheet).
    var lastRefusal: EditSession.Refusal?
    /// The user chose to close despite unsaved changes.
    var closingConfirmed = false
    /// The window that shows this comparison's sheets and edited dot when
    /// it lives elsewhere (a text tab of a folder window); nil for its own.
    weak var hostWindow: NSWindow?
    /// Called when the unsaved state may have changed (for a host window).
    var onEditedChange: (() -> Void)?
    /// What to select after the next re-diff (a merged region).
    var pendingFocus: EditSession.Focus?
    /// Where to put the caret after the next re-diff (after an edit).
    var pendingCaret: (pane: DiffSide, side: DiffSide, line: Int, offset: Int)?
    private var cancellation: CancellationFlag?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private(set) var isLoading = false
    var pendingInitialChange: Int?
    private var textSizeOffset: CGFloat = 0
    private var loadStarted: UInt64 = 0
    private var loadTimings: [String: Any] = [:]
    private var stallMonitor: MainThreadStallMonitor?
    private var scrollBench: ScrollBench?
    private(set) var ignoreWhitespace: Bool
    /// The next load re-diffs the same files: keep the scroll position.
    var keepPositionOnLoad = false
    private var wrapBench: WrapBench?
    /// The files of this comparison and which two are compared (the file
    /// shelf; two files unless more were opened or added).
    var shelf: ShelfModel
    let shelfView = FileShelfView()
    /// Called when the title, the files or the badge change (for a host
    /// window's tab strip).
    var onChromeChange: (() -> Void)?
    /// Continuous spell checking for the swapped-in editor.
    var checksSpellingWhileTyping = false
    var speech: AVSpeechSynthesizer?
    /// Where Check Spelling looks next (UTF-16 offset in the B text).
    var spellingOffset = 0

    init(a: URL, b: URL, initialChange: Int? = nil) {
        urlA = a
        urlB = b
        pendingInitialChange = initialChange
        let settings = TextSettings()
        ignoreWhitespace = settings.ignoreWhitespace
        blocksView = BlocksDiffView(font: settings.font, theme: settings.theme)
        blocksView.setMode(settings.viewMode)
        blocksView.setWrapsLines(settings.wrapLines)
        find = FindController(view: blocksView)
        session = EditSession(a: a, b: b)
        shelf = ShelfModel(files: [ShelfEntry(url: a), ShelfEntry(url: b)])
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultFrameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        pathBar = PathBarView(target: nil, swapAction: #selector(swapSides(_:)))
        bottomBar = BottomBarView(target: nil, previous: #selector(selectPreviousChange(_:)),
                                  next: #selector(selectNextChange(_:)))
        super.init(window: window)
        window.setFrame(NSRect(origin: .zero, size: Self.defaultFrameSize), display: false)
        window.contentMinSize = Self.minimumContentSize
        window.title = "Prism"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("prism.comparison")
        window.delegate = self
        pathBar.swapButton.target = self
        bottomBar.previousButton.target = self
        bottomBar.nextButton.target = self
        bottomBar.layoutControl.target = self
        bottomBar.layoutControl.action = #selector(layoutControlChanged(_:))
        bottomBar.layoutControl.selectedSegment = blocksView.mode.index
        bottomBar.ignoreWhitespaceButton.target = self
        bottomBar.ignoreWhitespaceButton.action = #selector(toggleIgnoreWhitespace(_:))
        bottomBar.ignoreWhitespaceButton.state = ignoreWhitespace ? .on : .off
        find.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.content.findBar = visible ? self.find.bar : nil
        }

        content.tabStrip = tabStrip
        content.pathBar = pathBar
        content.bottomBar = bottomBar
        content.body = placeholder
        content.onDrop = { [weak self] urls, point in self?.accept(urls, at: point) ?? false }
        window.contentView = content

        blocksView.onSelectionChange = { [weak self] index in self?.selectionChanged(index) }
        blocksView.onFirstPaint = { [weak self] in self?.firstPaint() }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: TextSettings.didChange, object: nil)
        updateChrome()
        setUpEditing()
        setUpShelf()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window and starts loading.
    func present(cascadingFrom previous: NSWindow? = nil) {
        guard let window else { return }
        if let previous {
            window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX,
                                                                              y: previous.frame.maxY)))
        } else {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        reload()
    }

    /// Reads both files again and recompares them.
    func reload() {
        texts = nil
        load(reread: true)
    }

    var title: String { "\(urlA.lastPathComponent) | \(urlB.lastPathComponent)" }

    /// The number in the tab strip's badge.
    var fileCount: Int { shelf.count }

    /// Sides whose path bar shows only a name (`PathBarView.Display`), such
    /// as a private copy whose folder means nothing to the user.
    var pathDisplay: (a: PathBarView.Display, b: PathBarView.Display) = (.path, .path)

    /// A view docked on the left, below the tab strip (a changeset's file
    /// list); nil for none.
    var sidebar: NSView? {
        get { content.sidebar }
        set { content.sidebar = newValue }
    }

    /// Shows another pair of files in this window.
    func showFiles(a: URL, b: URL, display: (a: PathBarView.Display, b: PathBarView.Display) = (.path, .path),
                   snapshots: Set<DiffSide> = []) {
        urlA = a
        urlB = b
        // A pair from elsewhere (a changeset's file) replaces the shelf.
        if shelf.entryA?.url != a || shelf.entryB?.url != b {
            shelf = ShelfModel(files: [ShelfEntry(url: a, display: display.a, isSnapshot: snapshots.contains(.a)),
                                       ShelfEntry(url: b, display: display.b, isSnapshot: snapshots.contains(.b))])
        }
        pathDisplay = display
        session.snapshotSides = snapshots
        texts = nil
        updateChrome()
        load(reread: true)
    }

    func updateChrome() {
        tabStrip.setTitle(title, fileCount: fileCount)
        pathBar.setURLs(a: urlA, b: urlB, display: pathDisplay)
        window?.setAccessibilityLabel(title)
        shelfView.show(shelf)
        onChromeChange?()
    }

    // MARK: loading

    /// Debug aid for responsiveness tests: `PRISM_DEBUG_DIFF_DELAY_MS`
    /// makes every load wait that long (cancellably) before diffing.
    nonisolated private static var debugDelayMilliseconds: Int {
        Int(ProcessInfo.processInfo.environment["PRISM_DEBUG_DIFF_DELAY_MS"] ?? "") ?? 0
    }

    private struct LoadResult: Sendable {
        var texts: (a: LoadedText, b: LoadedText)
        var model: ComparisonModel
        var readMilliseconds: Double
        var buildMilliseconds: Double
    }

    /// Reads (when `reread` or nothing is loaded yet) and diffs the files.
    func load(reread: Bool) {
        cancellation?.cancel()
        loadTask?.cancel()
        let flag = CancellationFlag()
        cancellation = flag
        generation += 1
        let current = generation
        isLoading = true
        loadRereads = reread || texts == nil
        let quiet = quietLoad && !loadRereads
        quietLoad = false
        if !quiet { bottomBar.setChange(nil, of: 0, loading: true) }
        let urls = (urlA, urlB)
        let resolved = loadRereads ? [] : session.resolvedRegions
        let existing = reread ? nil : texts
        let whitespace: WhitespaceMode = ignoreWhitespace ? .ignoreEdgeWhitespace : .exact
        let source = TextSources.current
        loadStarted = DispatchTime.now().uptimeNanoseconds
        if PerfLog.isEnabled {
            let monitor = MainThreadStallMonitor()
            monitor.start()
            stallMonitor = monitor
        }

        Task { [weak self] in
            try? await Task.sleep(for: Self.placeholderDelay)
            guard let self, self.generation == current, self.isLoading, !quiet else { return }
            self.placeholder.showLoading()
            self.content.body = self.placeholder
            PerfLog.record("placeholder", ["shown": true])
        }

        loadTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<LoadResult, any Error> in
                Result {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let pair = try existing ?? (source.load(urls.0), source.load(urls.1))
                    let read = DispatchTime.now().uptimeNanoseconds
                    var waited = 0
                    while waited < Self.debugDelayMilliseconds, !flag.isCancelled {
                        usleep(10_000)
                        waited += 10
                    }
                    let model = try ComparisonModel.build(a: pair.a, b: pair.b, whitespace: whitespace,
                                                          resolved: resolved, cancellation: flag)
                    let built = DispatchTime.now().uptimeNanoseconds
                    return LoadResult(texts: pair, model: model,
                                      readMilliseconds: Double(read - start) / 1e6,
                                      buildMilliseconds: Double(built - read) / 1e6)
                }
            }.value
            guard let self, self.generation == current else { return }
            self.finishLoad(outcome)
        }
    }

    private func finishLoad(_ outcome: Result<LoadResult, any Error>) {
        isLoading = false
        switch outcome {
        case let .success(result):
            texts = result.texts
            if loadRereads { session.load(a: result.texts.a, b: result.texts.b, urls: (urlA, urlB)) }
            loadTimings = [
                "readMs": PerfLog.rounded(result.readMilliseconds),
                "diffMs": PerfLog.rounded(result.model.diffMilliseconds),
                "buildMs": PerfLog.rounded(result.buildMilliseconds),
                "linesA": result.model.a.lineCount,
                "linesB": result.model.b.lineCount,
                "changes": result.model.changeCount,
            ]
            content.body = blocksView
            content.layoutSubtreeIfNeeded()
            if case let .region(a, b)? = pendingFocus, let index = result.model.change(covering: a, b) {
                pendingInitialChange = index + 1
            }
            pendingFocus = nil
            blocksView.show(result.model, initialChange: pendingInitialChange, keepingPosition: keepPositionOnLoad)
            // Draw now rather than at the next display cycle, which AppKit
            // may postpone for a window of an inactive app.
            if (content.window ?? window)?.isVisible == true { content.displayIfNeeded() }
            if let caret = pendingCaret {
                blocksView.placeCaret(pane: caret.pane, side: caret.side, line: caret.line, offset: caret.offset)
            }
            pendingCaret = nil
            keepPositionOnLoad = false
            pendingInitialChange = nil
            find.refresh()
            editingStateChanged()
            if editStarted != 0 {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - editStarted) / 1e6
                editStarted = 0
                PerfLog.record("rediff", ["ms": PerfLog.rounded(ms), "changes": result.model.changeCount,
                                          "label": bottomBar.changeLabel.stringValue,
                                          "alignmentErrorPt": Double(blocksView.visibleAlignmentError())])
            }
        case let .failure(error):
            if case DiffError.cancelled = error { return }
            keepPositionOnLoad = false
            // Nothing may keep driving the comparison that failed to reload.
            blocksView.clear()
            stallMonitor?.stop()
            stallMonitor = nil
            placeholder.showMessage(Self.describe(error))
            content.body = placeholder
            bottomBar.setChange(nil, of: 0, loading: true)
            PrismLog.diff.error("comparison failed to load: \(Self.describe(error), privacy: .private)")
            PerfLog.record("loadFailed", ["message": Self.describe(error)])
        }
    }

    static func describe(_ error: any Error) -> String {
        if let diffError = error as? DiffError {
            return "These files cannot be compared: \(diffError)"
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, let path = nsError.userInfo[NSFilePathErrorKey] as? String {
            let name = (path as NSString).lastPathComponent
            return "\u{201C}\(name)\u{201D} could not be opened. \(nsError.localizedFailureReason ?? nsError.localizedDescription)"
        }
        return nsError.localizedDescription
    }

    private func firstPaint() {
        let sinceLoad = Double(DispatchTime.now().uptimeNanoseconds - loadStarted) / 1e6
        let gap = stallMonitor.map { monitor -> Double in
            monitor.stop()
            return monitor.longestGapMilliseconds
        } ?? 0
        stallMonitor = nil
        guard PerfLog.isEnabled else { return }
        var fields = loadTimings
        fields["sinceProcessStartMs"] = PerfLog.rounded(PerfLog.millisecondsSinceProcessStart())
        fields["sinceLoadStartMs"] = PerfLog.rounded(sinceLoad)
        fields["wallMs"] = PerfLog.rounded(Date().timeIntervalSince1970 * 1000)
        fields["longestMainThreadGapMs"] = PerfLog.rounded(gap)
        fields["rssMB"] = PerfLog.rounded(PerfLog.residentMegabytes())
        fields["alignmentErrorPt"] = Double(blocksView.visibleAlignmentError())
        fields["mode"] = blocksView.mode.rawValue
        fields["wraps"] = blocksView.wrapsLines
        fields["ignoreWhitespace"] = ignoreWhitespace
        PerfLog.record("firstPaint", fields)
        runDebugHooks()
        if WrapBench.isRequested, wrapBench == nil, let window {
            let bench = WrapBench(view: blocksView, window: window)
            wrapBench = bench
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard self != nil else { return }
                bench.run()
            }
        }
        if ScrollBench.isRequested, scrollBench == nil {
            let bench = ScrollBench(view: blocksView)
            scrollBench = bench
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard self != nil else { return }
                bench.run()
            }
        }
    }

    /// Test hooks for headless acceptance runs (perf log only):
    /// `PRISM_DEBUG_LAYOUT=<mode>` switches the layout as the layout
    /// switcher would, and `PRISM_DEBUG_FIND=<text>` opens the find bar and
    /// searches for the text.
    private func runDebugHooks() {
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["PRISM_DEBUG_LAYOUT"], let mode = ViewMode(rawValue: name) {
            setMode(mode)
        }
        if let query = environment["PRISM_DEBUG_FIND"], !query.isEmpty {
            find.show()
            find.find(query)
        }
    }

    private func selectionChanged(_ index: Int?) {
        let count = blocksView.model?.changeCount ?? 0
        bottomBar.setChange(index, of: count)
        updateMergeControls()
        if PerfLog.isEnabled {
            var fields: [String: Any] = [
                "count": count,
                "label": bottomBar.changeLabel.stringValue,
                "scrollY": Double(blocksView.scrollY),
                "scrollYB": Double(blocksView.scrollB.contentView.bounds.minY),
                "scrollX": Double(blocksView.scrollA.contentView.bounds.minX),
                "scrollXB": Double(blocksView.scrollB.contentView.bounds.minX),
                "alignmentErrorPt": Double(blocksView.visibleAlignmentError()),
                "mode": blocksView.mode.rawValue,
            ]
            if let index, let probe = selectionProbe(index) {
                fields["change"] = index + 1
                fields["selectedGutterPoint"] = probe.point
                fields["selectedGutterColor"] = probe.color
            }
            PerfLog.record("selection", fields)
        }
    }

    /// Where the selected change's first line-number cell is on screen (in
    /// window points from the top-left corner of the frame) and the colour
    /// it should have there, for screenshot checks.
    /// In a tab of a document window the views live in that window, not in
    /// this controller's own (empty) one: the point is measured in the
    /// window the gutter is really in.
    func selectionProbe(_ index: Int) -> (point: [Double], color: String)? {
        guard let model = blocksView.model else { return nil }
        let block = model.layout.blocks[model.layout.changes[index]]
        let pane: DiffSide = block.isInsert && blocksView.mode != .unified ? .b : .a
        guard let geometry = blocksView.geometry(for: pane) else { return nil }
        let rows = geometry.rows.rows(ofChange: index)
        let gutter = pane == .b ? blocksView.gutterB : blocksView.gutterA
        guard let colors = blocksView.theme.colors(for: block) else { return nil }
        let y = geometry.y(ofRow: rows.lowerBound) - blocksView.scrollY(of: pane) + blocksView.metrics.lineHeight / 2
        guard let window = gutter.window ?? window else { return nil }
        let inWindow = gutter.convert(NSPoint(x: 4, y: y), to: nil)
        return ([Double(inWindow.x), Double(window.frame.height - inWindow.y)], colors.selectedGutter.hex)
    }

    // MARK: settings

    @objc private func settingsChanged(_ note: Notification) {
        editor.commit()
        let settings = TextSettings()
        blocksView.theme = settings.theme
        applyFont()
    }

    private func applyFont() {
        editor.commit()
        let base = TextSettings().font
        let size = min(max(base.pointSize + textSizeOffset, TextSettings.minimumFontSize), TextSettings.maximumFontSize)
        blocksView.setFont(NSFontManager.shared.convert(base, toSize: size))
    }

    // MARK: actions

    @objc func selectNextChange(_ sender: Any?) { blocksView.selectNextChange() }
    @objc func selectPreviousChange(_ sender: Any?) { blocksView.selectPreviousChange() }

    @objc func showBlocksLayout(_ sender: Any?) { setMode(.blocks) }
    @objc func showFluidLayout(_ sender: Any?) { setMode(.fluid) }
    @objc func showUnifiedLayout(_ sender: Any?) { setMode(.unified) }

    @objc private func layoutControlChanged(_ sender: NSSegmentedControl) {
        guard ViewMode.allCases.indices.contains(sender.selectedSegment) else { return }
        setMode(ViewMode.allCases[sender.selectedSegment])
    }

    /// Switches the layout and (unless `remember` is false, as when a
    /// tab is restored) remembers it for new comparisons.
    func setMode(_ mode: ViewMode, remember: Bool = true) {
        editor.commit()
        bottomBar.layoutControl.selectedSegment = mode.index
        if remember { TextSettings().viewMode = mode }
        guard mode != blocksView.mode else { return }
        blocksView.setMode(mode)
        find.refresh()
        PerfLog.record("layout", ["mode": mode.rawValue])
        onModeChange?()
    }

    /// View > Wrap Lines, for this window.
    @objc func toggleWrapLines(_ sender: Any?) {
        editor.commit()
        blocksView.setWrapsLines(!blocksView.wrapsLines)
        PerfLog.record("wrap", ["wraps": blocksView.wrapsLines])
    }

    /// View > Ignore Whitespace and the bottom-bar checkbox: re-diffs with
    /// line-edge whitespace ignored (or not). The text shown is unchanged.
    @objc func toggleIgnoreWhitespace(_ sender: Any?) {
        editor.commit()
        ignoreWhitespace.toggle()
        bottomBar.ignoreWhitespaceButton.state = ignoreWhitespace ? .on : .off
        keepPositionOnLoad = blocksView.model != nil
        load(reread: texts == nil)
    }

    /// Sets Ignore Whitespace for this comparison.
    func setIgnoreWhitespace(_ ignore: Bool) {
        if ignore != ignoreWhitespace { toggleIgnoreWhitespace(nil) }
    }

    // MARK: find

    @objc func showFindBar(_ sender: Any?) { find.show() }
    @objc func findNextMatch(_ sender: Any?) { find.next() }
    @objc func findPreviousMatch(_ sender: Any?) { find.previous() }

    /// Edit > Find > Use Selection for Find: searches for the selected text
    /// (its first line).
    @objc func useSelectionForFind(_ sender: Any?) {
        guard let text = blocksView.selectedText()?.split(separator: "\n", omittingEmptySubsequences: false).first,
              !text.isEmpty else { return }
        find.find(String(text))
    }

    /// Edit > Find > Jump to Selection.
    @objc func jumpToSelection(_ sender: Any?) { blocksView.revealSelection() }

    /// Esc closes the find bar.
    @objc override func cancelOperation(_ sender: Any?) { find.close(sender) }

    @objc func swapSides(_ sender: Any?) {
        editor.commit()
        session.swap()
        swap(&urlA, &urlB)
        shelf.swapAB()
        pathDisplay = (pathDisplay.b, pathDisplay.a)
        texts = texts.map { ($0.b, $0.a) }
        updateChrome()
        load(reread: texts == nil)
    }

    @objc func increaseTextSize(_ sender: Any?) {
        textSizeOffset += 1
        applyFont()
    }

    @objc func decreaseTextSize(_ sender: Any?) {
        textSizeOffset -= 1
        applyFont()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let enabled = validateEditingItem(menuItem) { return enabled }
        if let enabled = validateShellItem(menuItem) { return enabled }
        switch menuItem.action {
        case #selector(selectNextChange(_:)), #selector(selectPreviousChange(_:)):
            return showsComparison && (blocksView.model?.changeCount ?? 0) > 0 && !isLoading
        case #selector(showBlocksLayout(_:)), #selector(showFluidLayout(_:)), #selector(showUnifiedLayout(_:)):
            let mode: ViewMode = menuItem.action == #selector(showBlocksLayout(_:)) ? .blocks
                : menuItem.action == #selector(showFluidLayout(_:)) ? .fluid : .unified
            menuItem.state = blocksView.mode == mode ? .on : .off
            return true
        case #selector(toggleWrapLines(_:)):
            menuItem.state = blocksView.wrapsLines ? .on : .off
            return true
        case #selector(toggleIgnoreWhitespace(_:)):
            menuItem.state = ignoreWhitespace ? .on : .off
            return true
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)), #selector(showFindBar(_:)):
            return showsComparison
        case #selector(useSelectionForFind(_:)):
            return showsComparison && blocksView.selectedText()?.isEmpty == false
        case #selector(jumpToSelection(_:)):
            return showsComparison && blocksView.selection != nil
        case #selector(increaseTextSize(_:)):
            return blocksView.metrics.font.pointSize < TextSettings.maximumFontSize
        case #selector(decreaseTextSize(_:)):
            return blocksView.metrics.font.pointSize > TextSettings.minimumFontSize
        default:
            return true
        }
    }

    /// True when the window shows a loaded comparison (not a placeholder).
    var showsComparison: Bool { content.body === blocksView && blocksView.model != nil }

    /// Files dropped on the window: two or more replace both sides, one
    /// replaces the side it was dropped on.
    private func accept(_ urls: [URL], at point: NSPoint) -> Bool {
        let files = urls.filter { $0.isFileURL }
        // Dropping files would throw away unsaved edits.
        guard !files.isEmpty, !session.isDirty else { return false }
        if files.count >= 2 {
            urlA = files[0]
            urlB = files[1]
            shelf = ShelfModel(files: files.map { ShelfEntry(url: $0) })
            if files.count > 2 { setShelfVisible(true) }
        } else if point.x < content.bounds.midX {
            urlA = files[0]
            shelf.replace(sideA: true, with: ShelfEntry(url: files[0]))
        } else {
            urlB = files[0]
            shelf.replace(sideA: false, with: ShelfEntry(url: files[0]))
        }
        pathDisplay = (.path, .path)
        session.snapshotSides = []
        texts = nil
        updateChrome()
        load(reread: true)
        return true
    }

    // MARK: window

    func windowWillClose(_ notification: Notification) {
        cancellation?.cancel()
        loadTask?.cancel()
        generation += 1
        isLoading = false
        stallMonitor?.stop()
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }
}

/// The window's content: tab strip, path bar, the comparison (or a
/// placeholder) and the bottom bar, stacked top to bottom. Accepts dropped
/// files.
@MainActor
final class ComparisonContentView: NSView {
    static let tabStripHeight: CGFloat = 24
    static let pathBarHeight: CGFloat = 31
    static let bottomBarHeight: CGFloat = 37

    static let sidebarWidth: CGFloat = 260

    var tabStrip: NSView? { didSet { replace(oldValue, with: tabStrip) } }
    /// Docked on the left below the tab strip; the path bar, the comparison
    /// and the bottom bar take the rest of the width.
    var sidebar: NSView? { didSet { replace(oldValue, with: sidebar) } }
    var pathBar: NSView? { didSet { replace(oldValue, with: pathBar) } }
    /// The file shelf, below the path bar, when shown.
    var shelf: NSView? {
        didSet {
            guard shelf !== oldValue else { return }
            replace(oldValue, with: shelf)
        }
    }
    var bottomBar: NSView? { didSet { replace(oldValue, with: bottomBar) } }
    /// The find bar, between the path bar and the comparison, when shown.
    var findBar: NSView? {
        didSet {
            guard findBar !== oldValue else { return }
            replace(oldValue, with: findBar)
        }
    }
    var body: NSView? {
        didSet {
            guard body !== oldValue else { return }
            replace(oldValue, with: body)
        }
    }
    var onDrop: (([URL], NSPoint) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func replace(_ old: NSView?, with new: NSView?) {
        old?.removeFromSuperview()
        if let new { addSubview(new) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let tabStrip {
            tabStrip.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.tabStripHeight)
            y += Self.tabStripHeight
        }
        let x: CGFloat = sidebar == nil ? 0 : min(Self.sidebarWidth, floor(bounds.width / 3))
        sidebar?.frame = NSRect(x: 0, y: y, width: x, height: max(bounds.height - y, 0))
        let width = bounds.width - x
        pathBar?.frame = NSRect(x: x, y: y, width: width, height: Self.pathBarHeight)
        y += Self.pathBarHeight
        if let shelf {
            shelf.frame = NSRect(x: x, y: y, width: width, height: FileShelfView.height)
            y += FileShelfView.height
        }
        if let findBar {
            findBar.frame = NSRect(x: x, y: y, width: width, height: FindBarView.height)
            y += FindBarView.height
        }
        let bottom = bounds.height - Self.bottomBarHeight
        body?.frame = NSRect(x: x, y: y, width: width, height: max(bottom - y, 0))
        bottomBar?.frame = NSRect(x: x, y: bottom, width: width, height: Self.bottomBarHeight)
        // The swap button sits over the divider between the panes.
        (pathBar as? PathBarView)?.splitX = floor((width - 1) / 2)
    }

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        return onDrop?(fileURLs(sender), point) ?? false
    }
}
