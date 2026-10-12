// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismTestSupport
import Testing
@testable import PrismApp

// Tests of the M4 text views: Fluid, Unified, wrapping, find, selection,
// accessibility, and the M3 carry-over fixes.

private func text(_ string: String) -> LoadedText { UTF8TextSource.decode(Array(string.utf8)) }

private func fixtureModel(_ a: String, _ b: String, whitespace: WhitespaceMode = .exact) throws -> ComparisonModel {
    let source = UTF8TextSource()
    return try ComparisonModel.build(a: source.load(Corpus.fixture("text/\(a)")),
                                     b: source.load(Corpus.fixture("text/\(b)")), whitespace: whitespace)
}

@MainActor
private func host(_ model: ComparisonModel, mode: ViewMode = .blocks, wraps: Bool = false,
                  size: NSSize = NSSize(width: 1200, height: 700)) -> (BlocksDiffView, NSWindow) {
    _ = NSApplication.shared
    let view = BlocksDiffView(font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                              theme: BuiltinThemes.multicolorLight)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.setMode(mode)
    view.setWrapsLines(wraps)
    view.show(model)
    return (view, window)
}

/// Draws `rect` of `view` into an offscreen bitmap; returns milliseconds.
@MainActor
@discardableResult
private func render(_ view: NSView, _ rect: NSRect) -> Double {
    let rep = view.bitmapImageRepForCachingDisplay(in: rect)!
    let start = DispatchTime.now().uptimeNanoseconds
    view.cacheDisplay(in: rect, to: rep)
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

// MARK: row heights and pane rows

@Test func rowHeightsMapLinesAndRows() {
    let uniform = RowHeights(uniform: 10)
    #expect(uniform.isUniform && uniform.total == 10 && uniform.top(4) == 4 && uniform.row(atLine: 7) == 7)
    let heights = RowHeights([1, 3, 1, 2])
    #expect(!heights.isUniform)
    #expect(heights.total == 7)
    #expect((0 ..< 4).map(heights.top) == [0, 1, 4, 5])
    #expect((0 ..< 7).map(heights.row(atLine:)) == [0, 1, 1, 1, 2, 3, 3])
    #expect(heights.height(1) == 3 && heights.height(9) == 1)
    #expect(heights.row(atLine: 9) == 6 && heights.top(6) == 9)
    #expect(RowHeights([1, 1, 1]).isUniform)
}

@Test func unifiedRowsShowEachChangeAsALinesThenBLines() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let rows = PaneRows(kind: .unified, layout: model.layout, lineCounts: (21, 21))
    // 21 equal-or-A lines plus the B lines of the changes, plus the trailer.
    let changedB = model.layout.changes.reduce(0) { $0 + model.layout.blocks[$1].b.count }
    #expect(rows.count == 21 + changedB + 1)
    #expect(rows.content(0) == .line(.a, 0, block: 0))
    // Row 1 is "import OSLog", an insert: a B line.
    guard case let .line(side, line, _) = rows.content(1) else { Issue.record("row 1"); return }
    #expect(side == .b && line == 1)
    #expect(rows.numbers(ofRow: 0) == (1, 1))
    #expect(rows.numbers(ofRow: 1) == (nil, 2))
    #expect(rows.numbers(ofRow: 2) == (2, 3))
    // Every change's rows: its A lines, then its B lines.
    for change in 0 ..< model.changeCount {
        let block = model.layout.blocks[model.layout.changes[change]]
        let range = rows.rows(ofChange: change)
        #expect(range.count == block.a.count + block.b.count)
        for (offset, row) in range.enumerated() {
            let expected: PaneRow = offset < block.a.count
                ? .line(.a, block.a.lowerBound + offset, block: model.layout.changes[change])
                : .line(.b, block.b.lowerBound + offset - block.a.count, block: model.layout.changes[change])
            #expect(rows.content(row) == expected)
        }
    }
    #expect(rows.row(ofLine: 1, side: .b) == 1)
    #expect(rows.row(ofLine: 1, side: .a) == 2)
}

@Test func fluidRowsAreTheSidesOwnLines() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let a = PaneRows(kind: .fluid(.a), layout: model.layout, lineCounts: (21, 21))
    #expect(a.count == 22)
    #expect(a.rows(ofChange: 0).isEmpty) // the OSLog insert has no A lines
    #expect(a.content(5) == .line(.a, 5, block: model.layout.block(ofLine: 5, side: .a)!))
}

// MARK: layouts in the view

@MainActor
@Test func fluidKeepsPanesUnpaddedAndSyncsBlockByBlock() throws {
    let model = try fixtureModel("big_a.txt", "big_b.txt")
    let (view, _) = host(model, mode: .fluid)
    let a = try #require(view.geometryA), b = try #require(view.geometryB)
    #expect(a.rows.count == model.a.lineCount + 1 && b.rows.count == model.b.lineCount + 1)
    #expect(view.divider.frame.width == BlocksDiffView.fluidGutterWidth)
    // Scrolling A drags B through the same fraction of the same block.
    view.scroll(toY: 400_000)
    let yA = view.scrollY(of: .a), yB = view.scrollY(of: .b)
    #expect(abs(view.fluidCounterpart(ofY: yA, from: .a) - yB) <= 1)
    // An unchanged line at the top of A sits at the top of B as well.
    let row = a.row(atY: yA + view.metrics.topInset)
    if case let .line(_, lineA, block) = a.rows.content(row), model.layout.blocks[block].kind == .equal {
        let lineB = model.layout.blocks[block].b.lowerBound + lineA - model.layout.blocks[block].a.lowerBound
        #expect(abs((a.y(ofRow: lineA) - yA) - (b.y(ofRow: lineB) - yB)) <= 1)
    }
    // Navigation centres the change in both panes.
    view.selectChange(472, scroll: true)
    for pane in [DiffSide.a, .b] {
        let geometry = try #require(view.geometry(for: pane))
        let rows = geometry.rows.rows(ofChange: 472)
        let middle = (geometry.y(ofRow: rows.lowerBound) + geometry.y(ofRow: rows.upperBound)) / 2
        let clip = view.scrollView(for: pane).contentView.bounds
        #expect(abs(middle - clip.midY) <= view.metrics.lineHeight)
    }
}

@MainActor
@Test func unifiedUsesOnePaneWithTwoNumberColumns() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let (view, _) = host(model, mode: .unified)
    #expect(view.scrollB.isHidden && view.gutterB.isHidden && view.divider.isHidden)
    #expect(view.scrollA.frame.width > view.bounds.width * 0.8)
    #expect(view.gutterA.frame.width >= view.metrics.gutterWidth(maxNumber: 22) * 2)
    view.selectNextChange()
    #expect(view.selectedChange == 1)
    render(view, view.bounds)
}

@MainActor
@Test func switchingLayoutsKeepsTheTopLine() throws {
    let model = try fixtureModel("big_a.txt", "big_b.txt")
    let (view, _) = host(model)
    view.selectChange(300, scroll: true)
    let before = view.scrollAnchor()
    for mode in [ViewMode.fluid, .unified, .blocks] {
        view.setMode(mode)
        let after = view.scrollAnchor()
        #expect(after.line == before.line, "mode \(mode)")
    }
    #expect(view.selectedChange == 300)
}

// MARK: wrapping

@MainActor
@Test func wrappedBlocksStayAlignedThroughResizes() throws {
    let model = try fixtureModel("big_a.txt", "big_b.txt")
    let (view, window) = host(model, wraps: true, size: NSSize(width: 1200, height: 700))
    view.selectChange(472, scroll: true)
    var times: [Double] = []
    for width in [900.0, 700, 600] {
        let start = DispatchTime.now().uptimeNanoseconds
        window.setContentSize(NSSize(width: width, height: 700))
        view.layoutSubtreeIfNeeded()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        let geometry = try #require(view.geometryA)
        #expect(!geometry.heights.isUniform, "lines wrap at \(width) pt")
        #expect(view.visibleAlignmentError() == 0)
        // The shared geometry: every unchanged line and its counterpart
        // start at the same y, everywhere in the document.
        let b = try #require(view.geometryB)
        #expect(geometry.heights == b.heights)
        #expect(view.paneA.frame.height == view.paneB.frame.height)
        #expect(view.paneA.frame.width <= view.scrollA.contentView.bounds.width + 1)
        // The wrapped text fits the clip view that is finally on screen,
        // with nothing to scroll sideways.
        for (pane, columns) in [(DiffSide.a, view.wrapColumns.a), (.b, view.wrapColumns.b)] {
            let clip = view.scrollView(for: pane).contentView.bounds.width
            #expect(CGFloat(columns) * view.metrics.charWidth + view.metrics.textInset * 2 <= clip + 0.5,
                    "\(pane): \(columns) columns in \(clip) pt")
            #expect(view.textPane(pane).frame.width <= clip + 0.5)
        }
    }
    // Recomputing the heights of 100k rows must fit in a frame or two.
    #expect(times.max()! < 100, "resize took \(times) ms")
    // A wrapped line takes as many visual lines as its columns need, and
    // its padding on the other side matches.
    let columns = view.wrapColumns.a
    #expect(columns > 8)
    for row in 0 ..< 200 {
        guard case let .line(_, line, _) = view.geometryA!.rows.content(row) else { continue }
        let need = WrapHeights.lines(Int(model.a.lineColumns[line]), columns)
        #expect(view.geometryA!.heights.height(row) >= need)
    }
    render(view, view.bounds)
}

@MainActor
@Test func wrappedRowsTakeTheTallerSide() {
    let a = text("short\n" + String(repeating: "x", count: 100) + "\nend\n")
    let b = text("short\nother\nend\n")
    let model = try! ComparisonModel.build(a: a, b: b, whitespace: .exact)
    let heights = WrapHeights(a: model.a.lineColumns, b: model.b.lineColumns, columnsA: 30, columnsB: 30)
        .blocks(model.layout)
    #expect(heights.height(1) == 4) // 100 columns at 30 per line
    #expect(heights.height(0) == 1 && heights.height(2) == 1)
    let unified = WrapHeights(a: model.a.lineColumns, b: model.b.lineColumns, columnsA: 30, columnsB: 30)
        .unified(model.layout)
    #expect((0 ..< unified.count).map(unified.height) == [1, 4, 1, 1, 1])
}

// MARK: long lines (carry-over: draw only the visible slice)

@MainActor
@Test func aHugeLineDrawsOnlyItsVisibleSlice() throws {
    let huge = String(repeating: "abcdefghij klmnopqrstu vwxyz ", count: 190_000) // ~5.5 MB
    let model = try ComparisonModel.build(a: text("first\n" + huge + "\nlast\n"),
                                          b: text("first\n" + huge + "\nlast!\n"), whitespace: .exact)
    let (view, _) = host(model)
    #expect(view.paneA.frame.width <= BlocksDiffView.maximumDocumentWidth)
    let visible = view.scrollA.contentView.bounds
    render(view.paneA, visible)
    let second = render(view.paneA, visible)
    let shaper = try #require(view.shaper(for: .a))
    let line = shaper.line(1)
    #expect(line.chunkCount > 1000)
    #expect(line.shapedCount <= 3, "shaped \(line.shapedCount) chunks for one screen")
    #expect(second < 50, "a redraw took \(second) ms")
    // Far to the right: still only the chunks on screen.
    view.scrollA.contentView.scroll(to: NSPoint(x: 600_000, y: 0))
    let far = render(view.paneA, view.scrollA.contentView.bounds)
    #expect(line.shapedCount <= 7)
    #expect(far < 50, "a far redraw took \(far) ms")
    // Offsets and positions agree across chunk boundaries.
    for offset in [0, 2047, 2048, 2049, 100_000, 1_000_003] {
        let x = shaper.x(ofOffset: offset, in: line, line: 1)
        #expect(abs(shaper.offset(atX: x + 0.1, in: line, line: 1) - offset) <= 1)
    }
}

@MainActor
@Test func wordHighlightOffsetsAreCachedPerLine() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let shaper = LineShaper(text: model.b, metrics: TextMetrics(font: .monospacedSystemFont(ofSize: 11, weight: .regular)))
    // b.swift line 4: "/// Computes a friendly greeting for a user."
    let line = shaper.line(3)
    #expect(line === shaper.line(3))
    let words = line.words
    #expect(!words.isEmpty)
    let string = model.b.text(ofLine: 3) as NSString
    #expect(string.substring(with: NSRange(location: words[0].lowerBound, length: words[0].count))
        .contains("friendly"))
}

// MARK: find

@Test func findCountsMatchTheReference() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let a = FindEngine.search(model.a, side: .a, query: "name")
    let b = FindEngine.search(model.b, side: .b, query: "name")
    #expect(a.count == 4 && b.count == 5)
    #expect(a.map(\.line) == [4, 8, 13, 17])
    #expect(FindEngine.summary(count: 4, current: 0, scope: .a, other: 5)
        == ("1st of 4 results in A", "(5 more in B)"))
    #expect(FindEngine.summary(count: 4, current: 1, scope: .a, other: 0) == ("2nd of 4 results in A", "(No more in B)"))
    #expect(FindEngine.summary(count: 0, current: nil, scope: .b, other: 3) == ("No results in B", "(3 in A)"))
    #expect(FindEngine.summary(count: 1, current: 0, scope: nil, other: 0) == ("1st of 1 result", nil))
    // Case- and diacritic-insensitive, literal.
    let accents = try ComparisonModel.build(a: text("Café NAME na.e\n"), b: text("x\n"), whitespace: .exact)
    #expect(FindEngine.search(accents.a, side: .a, query: "cafe").count == 1)
    #expect(FindEngine.search(accents.a, side: .a, query: "name").count == 1)
    #expect(FindEngine.search(accents.a, side: .a, query: "na.").count == 1)
    #expect((1 ... 24).map(FindEngine.ordinal).suffix(14).prefix(4) == ["11th", "12th", "13th", "14th"])
    #expect(FindEngine.ordinal(22) == "22nd" && FindEngine.ordinal(103) == "103rd")
}

@MainActor
@Test func findBarReportsAndStepsThroughResults() async throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let (view, _) = host(model)
    let find = FindController(view: view)
    find.show()
    find.find("name")
    // Generous: other tests may keep the main actor busy for seconds.
    let deadline = ContinuousClock.now + .seconds(90)
    while find.isSearching, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(find.summary == "1st of 4 results in A")
    #expect(find.note == "(5 more in B)")
    #expect(view.findHighlights.dims)
    #expect(view.findHighlights.lines[.a]?.count == 4)
    find.next()
    #expect(find.summary == "2nd of 4 results in A")
    find.previous()
    find.previous()
    #expect(find.summary == "4th of 4 results in A")
    find.setScope(.b)
    #expect(find.summary.hasSuffix("of 5 results in B"))
    #expect(find.note == "(4 more in A)")
    render(view, view.bounds)
    find.close(nil)
    #expect(!view.findHighlights.dims)
    // Unified searches its single text: unchanged lines once.
    view.setMode(.unified)
    find.show()
    find.refresh()
    while find.isSearching, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(find.summary == "1st of 8 results")
    #expect(find.note == nil)
}

// MARK: ignore whitespace

@Test func ignoringWhitespaceLeavesIndentOnlyEditsUnchanged() throws {
    let a = text("func f() {\n    let x = 1\n\treturn x\n}\n")
    let b = text("func f() {\n        let x = 1   \n  return x\n}\n")
    #expect(try ComparisonModel.build(a: a, b: b, whitespace: .exact).changeCount == 1)
    let ignoring = try ComparisonModel.build(a: a, b: b, whitespace: .ignoreEdgeWhitespace)
    #expect(ignoring.changeCount == 0)
    // The text shown is the files' own.
    #expect(ignoring.b.text(ofLine: 1) == "        let x = 1   ")
}

@Test func generatedIndentPairHasNoChangesIgnoringWhitespace() throws {
    let a = Corpus.generatedDirectory.appending(path: "ind_a.txt")
    let b = Corpus.generatedDirectory.appending(path: "ind_b.txt")
    guard FileManager.default.fileExists(atPath: a.path) else { return } // generate.py not run
    let source = UTF8TextSource()
    let model = try ComparisonModel.build(a: source.load(a), b: source.load(b), whitespace: .ignoreEdgeWhitespace)
    #expect(model.changeCount == 0)
}

// MARK: selection, copy and accessibility

@MainActor
@Test func selectionCopiesTextAcrossRowsAndSkipsPadding() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let (view, _) = host(model)
    let geometry = try #require(view.geometryA)
    // A rows 0...2: "import Foundation", padding (OSLog insert), "".
    view.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 0, offset: 7),
                                    head: TextPosition(row: 3, offset: 3)))
    #expect(view.selectedText() == "Foundation\n\n///")
    view.copy(nil)
    #expect(NSPasteboard.general.string(forType: .string) == "Foundation\n\n///")
    view.selectAllText()
    let all = try #require(view.selectedText())
    #expect(all.hasPrefix("import Foundation\n") && all.contains("// trailing comment"))
    #expect(all.components(separatedBy: "\n").count >= 21)
    // A click maps back to the line under it.
    let pane = view.paneA
    let y = geometry.y(ofRow: 3) + 2
    let position = try #require(pane.position(at: NSPoint(x: view.metrics.textInset + view.metrics.charWidth * 4.2, y: y)))
    #expect(position.row == 3 && position.offset == 4)
}

@MainActor
@Test func accessibilityExposesVisibleLinesAndTheCurrentOne() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let (view, _) = host(model)
    let children = try #require(view.paneA.accessibilityChildren() as? [LineAccessibilityElement])
    #expect(children.count >= 21)
    #expect(children[0].accessibilityLabel() == "A line 1")
    #expect(children[0].accessibilityValue() as? String == "import Foundation")
    view.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 10, offset: 0),
                                    head: TextPosition(row: 10, offset: 0)))
    let focused = try #require(view.paneA.accessibilityFocusedUIElement as? LineAccessibilityElement)
    #expect(focused.accessibilityLabel() == "A line 9")
    #expect((focused.accessibilityValue() as? String)?.contains("Hello") == true)
    #expect(focused.isAccessibilityFocused())
}

// MARK: carry-over fixes

@MainActor
@Test func textSizeChangesKeepTheTopLineFractionAndColumn() throws {
    let model = try fixtureModel("big_a.txt", "big_b.txt")
    let (view, _) = host(model)
    let lineHeight = view.metrics.lineHeight
    view.scroll(toY: view.metrics.y(ofRow: 5000) + (lineHeight / 2).rounded() - view.metrics.topInset)
    view.scrollA.contentView.scroll(to: NSPoint(x: view.metrics.charWidth * 10, y: view.scrollY))
    let before = view.scrollAnchor()
    for size in [12.0, 13, 12, 11, 16] {
        view.setFont(.monospacedSystemFont(ofSize: size, weight: .regular))
        let after = view.scrollAnchor()
        #expect(after.line == before.line, "size \(size)")
        #expect(abs(after.fraction - before.fraction) < 0.15)
    }
    view.setFont(.monospacedSystemFont(ofSize: 11, weight: .regular))
    #expect(view.scrollAnchor().line == before.line)
}

@Test func astralCharactersCountAsThreeColumns() {
    #expect(ComparisonSide.maxColumns(Array("ab\u{1F600}\u{1F600}".utf8)) == 8)
    #expect(ComparisonSide.maxColumns(Array("\t\u{4E2D}x".utf8)) == 7)
    let index = LineIndex(starts: [0, 9, 14])
    #expect(ComparisonSide.lineColumns(Array("\u{1F600}\u{1F600}x\nab\r\n".utf8), lines: index) == [7, 2])
}

@MainActor
@Test func aFailedReloadStopsNavigation() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appending(path: "prism-m4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let b = directory.appending(path: "b.swift")
    try FileManager.default.copyItem(at: Corpus.fixture("text/b.swift"), to: b)
    let controller = ComparisonWindowController(a: Corpus.fixture("text/a.swift"), b: b)
    controller.reload()
    var deadline = ContinuousClock.now + .seconds(90)
    while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.showsComparison)
    try FileManager.default.removeItem(at: b)
    controller.reload()
    deadline = ContinuousClock.now + .seconds(90)
    while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!controller.showsComparison)
    #expect(controller.blocksView.model == nil)
    let item = NSMenuItem(title: "Next Change", action: #selector(ComparisonWindowController.selectNextChange(_:)),
                          keyEquivalent: "")
    #expect(!controller.validateMenuItem(item))
    controller.selectNextChange(nil) // must not crash or drive anything
    #expect(controller.blocksView.selectedChange == nil)
}

@MainActor
@Test func placeholderSpinnerStaysHiddenUntilLoadingShows() {
    let placeholder = PlaceholderView()
    #expect(!placeholder.isSpinnerVisible)
    placeholder.showLoading()
    #expect(placeholder.isSpinnerVisible)
    placeholder.showMessage("x")
    #expect(!placeholder.isSpinnerVisible)
}

@MainActor
@Test func themeColoursAreMadeOncePerTheme() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let (view, _) = host(model)
    let background = view.palette.background
    render(view, view.bounds)
    #expect(view.palette.background === background)
    view.theme = BuiltinThemes.multicolorDark
    #expect(view.palette.background !== background)
    #expect(view.palette.background == BuiltinThemes.multicolorDark.background.cgColor)
}

// MARK: persistence

@MainActor
@Test func viewModeAndWrapPersistAsDefaults() throws {
    let suite = "prism.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = TextSettings(defaults: defaults)
    #expect(settings.viewMode == .blocks)
    #expect(!settings.wrapLines)
    settings.viewMode = .unified
    settings.wrapLines = true
    #expect(TextSettings(defaults: defaults).viewMode == .unified)
    #expect(TextSettings(defaults: defaults).wrapLines)
    defaults.set("bogus", forKey: TextSettings.Key.viewMode)
    #expect(settings.viewMode == .blocks)
}

// MARK: overview, caret keys, window toggles

@MainActor
@Test func scrollerTrackShowsADotPerChange() throws {
    let model = try fixtureModel("big_a.txt", "big_b.txt")
    let (view, _) = host(model)
    #expect(view.overviewB.marks.count == model.changeCount)
    #expect(view.overviewB.marks.allSatisfy { $0.top >= 0 && $0.bottom <= 1 && $0.top <= $0.bottom })
    #expect(view.overviewA.marks.isEmpty)
    view.setMode(.unified)
    #expect(view.overviewA.marks.count == model.changeCount && view.overviewB.marks.isEmpty)
    view.findHighlights = FindHighlights(lines: [.a: [10: [0 ..< 4]]], current: nil, dims: true)
    #expect(view.overviewA.marks.filter { $0.kind == .match }.count == 1)
}

@MainActor
@Test func arrowKeysMoveTheCurrentLineOverPadding() throws {
    let model = try fixtureModel("a.swift", "b.swift")
    let (view, _) = host(model)
    #expect(view.selection?.head.row == 0)
    view.moveCaret(by: 1) // row 1 is padding (the OSLog insert)
    #expect(view.selection?.head.row == 2)
    view.moveCaret(by: 1)
    view.moveCaret(by: 1, extending: true)
    #expect(view.selection?.anchor.row == 3 && view.selection?.head.row == 4)
    #expect(view.selectedText() == "/// Computes greeting for a user.\n")
    view.moveCaret(by: -1)
    #expect(view.selection?.head.row == 3 && view.selection!.isEmpty)
}

@MainActor
@Test func windowTogglesRediffAndSwitchLayouts() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appending(path: "prism-m4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = directory.appending(path: "a.txt"), b = directory.appending(path: "b.txt")
    try Data("x {\n  y\n}\n".utf8).write(to: a)
    try Data("x {\n\t\ty  \n}\n".utf8).write(to: b)
    let controller = ComparisonWindowController(a: a, b: b)
    func settle() async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
    controller.reload()
    try await settle()
    let initial = controller.ignoreWhitespace
    controller.toggleIgnoreWhitespace(nil)
    try await settle()
    #expect(controller.ignoreWhitespace == !initial)
    #expect(controller.blocksView.model?.changeCount == (initial ? 1 : 0))
    #expect(controller.bottomBar.ignoreWhitespaceButton.state == (initial ? .off : .on))
    controller.toggleWrapLines(nil)
    #expect(controller.blocksView.wrapsLines != TextSettings().wrapLines)
    let saved = UserDefaults.standard.string(forKey: TextSettings.Key.viewMode)
    defer { UserDefaults.standard.set(saved, forKey: TextSettings.Key.viewMode) }
    controller.showFluidLayout(nil)
    #expect(controller.blocksView.mode == .fluid && controller.bottomBar.layoutControl.selectedSegment == 1)
    #expect(TextSettings().viewMode == .fluid)
    let item = NSMenuItem(title: "Fluid", action: #selector(ComparisonWindowController.showFluidLayout(_:)),
                          keyEquivalent: "")
    #expect(controller.validateMenuItem(item) && item.state == .on)
}
