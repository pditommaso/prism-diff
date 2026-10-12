// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import CoreText
import DiffCore
import PrismTestSupport
import Testing
@testable import PrismApp

// Regression tests for the M4 review findings: non-ASCII chunk placement and
// cuts, chunk memory, copy across characters and line ends, find offsets and
// stepping cost, highlights inside long ranges, and wrapping measured text.

private func t(_ s: String) -> LoadedText { UTF8TextSource.decode(Array(s.utf8)) }
@MainActor private let font11 = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

@MainActor
private func mkHost(_ model: ComparisonModel, mode: ViewMode = .blocks, wraps: Bool = false,
                    size: NSSize = NSSize(width: 1200, height: 700)) -> (BlocksDiffView, NSWindow) {
    _ = NSApplication.shared
    let view = BlocksDiffView(font: font11, theme: BuiltinThemes.multicolorLight)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.setMode(mode)
    view.setWrapsLines(wraps)
    view.show(model)
    return (view, window)
}

private func same(_ line: String) throws -> ComparisonModel {
    try ComparisonModel.build(a: t(line + "\n"), b: t(line + "\n"), whitespace: .exact)
}

// MARK: 1 and 9: measured placement and wrapping of non-ASCII lines

@MainActor
@Test func nonASCIIChunksArePlacedByMeasuredWidth() throws {
    let metrics = TextMetrics(font: font11)
    for (name, unit) in [("combining", "e\u{0301}"), ("cjk", "\u{4E2D}"), ("emoji", "\u{1F600}"),
                         ("arrow", "\u{2192}"), ("devanagari", "\u{0915}"), ("arabic", "\u{0645}"),
                         ("hebrew", "\u{05D0}"), ("thai", "\u{0E01}")] {
        let model = try same(String(repeating: unit, count: 3000))
        let shaper = LineShaper(text: model.a, metrics: metrics)
        let shaped = shaper.line(0)
        #expect(shaped.chunkCount > 1, "\(name)")
        #expect(!shaped.isASCII)
        // Chunk i + 1 starts exactly where chunk i ends: no gap, no overlap.
        var x: CGFloat = 0
        for index in 0 ..< shaped.chunkCount {
            #expect(abs(shaper.chunkX(shaped, line: 0, chunk: index) - x) < 0.5, "\(name) chunk \(index)")
            let ct = shaper.ctLine(shaped, line: 0, chunk: index)
            x += CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
        }
        #expect(abs(shaper.width(of: shaped, line: 0) - x) < 0.5, "\(name) width")
        // Hit testing follows the same placement (left-to-right scripts:
        // in a right-to-left run offset 0 sits at the run's right edge).
        guard !["arabic", "hebrew"].contains(name) else { continue }
        let boundary = shaped.chunks[1].utf16
        let boundaryX = shaper.x(ofOffset: boundary, in: shaped, line: 0)
        #expect(abs(boundaryX - shaper.chunkX(shaped, line: 0, chunk: 1)) < 0.5)
        #expect(abs(shaper.offset(atX: boundaryX + 0.2, in: shaped, line: 0) - boundary) <= unit.utf16.count)
    }
    // An ASCII line keeps column placement.
    let ascii = try same(String(repeating: "abc ", count: 2000))
    let shaper = LineShaper(text: ascii.a, metrics: metrics)
    let shaped = shaper.line(0)
    #expect(shaped.isASCII && !shaped.isMeasured)
    #expect(shaper.chunkX(shaped, line: 0, chunk: 1) == CGFloat(shaped.chunks[1].column) * metrics.charWidth)
}

@MainActor
@Test func wrappingNonASCIITextUsesItsMeasuredWidth() throws {
    for line in [String(repeating: "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} ", count: 60),
                 String(repeating: "\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} ", count: 40),
                 String(repeating: "\u{4E2D}\u{6587}", count: 200)] {
        let model = try ComparisonModel.build(a: t(line + "\n"), b: t("x\n"), whitespace: .exact)
        let (view, _) = mkHost(model, wraps: true, size: NSSize(width: 800, height: 600))
        let shaper = try #require(view.shaper(for: .a))
        let width = shaper.width(of: shaper.line(0), line: 0)
        let segments = view.wrappedHeight(side: .a, line: 0)
        let wrap = CGFloat(view.wrapColumns.a) * view.metrics.charWidth
        #expect(CGFloat(segments) * wrap >= width - 0.5, "text cut: \(width) pt in \(segments) lines of \(wrap)")
        #expect(CGFloat(segments - 1) * wrap < width, "blank wrapped line")
        // Slices tile the line, each starting on a character boundary.
        var previous: CGFloat = 0
        for k in 0 ..< segments {
            let slice = try #require(view.wrapSlice(k, side: .a, line: 0, pane: .a))
            #expect(abs(slice.lowerBound - previous) < 0.01)
            #expect(slice.lowerBound >= CGFloat(k) * wrap - 0.01)
            previous = slice.upperBound
        }
        _ = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { view.cacheDisplay(in: view.bounds, to: $0) }
    }
}

// MARK: 4: chunk cuts never split a character

@MainActor
@Test func chunkCutsNeverSplitACharacter() throws {
    let metrics = TextMetrics(font: font11)
    for (name, cluster) in [("combining", "e\u{0301}"), ("flag", "\u{1F1EE}\u{1F1F9}"),
                            ("family", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}")] {
        var splits: [Int] = []
        for n in stride(from: 2030, through: 2120, by: 3) {
            let line = String(repeating: "a", count: n) + cluster + String(repeating: "b", count: 3000)
            let shaped = LineShaper(text: try same(line).a, metrics: metrics).line(0)
            let start = n, end = n + cluster.utf16.count
            if shaped.chunks.contains(where: { $0.utf16 > start && $0.utf16 < end }) { splits.append(n) }
        }
        #expect(splits.isEmpty, "\(name) split for prefixes \(splits)")
    }
    // A long run of clusters with no ASCII at all is still cut, between
    // whole clusters.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    let line = String(repeating: family, count: 800)
    let shaped = LineShaper(text: try same(line).a, metrics: metrics).line(0)
    #expect(shaped.chunkCount > 1)
    for chunk in shaped.chunks { #expect(chunk.utf16 % family.utf16.count == 0) }
}

// MARK: 7: shaped chunks are released

@MainActor
@Test func shapedChunksStayWithinTheirBudget() throws {
    let huge = String(repeating: "abcdefghij klmnopqrstu vwxyz ", count: 190_000)
    let model = try ComparisonModel.build(a: t("first\n" + huge + "\nlast\n"), b: t("q\n"), whitespace: .exact)
    let shaper = LineShaper(text: model.a, metrics: TextMetrics(font: font11))
    let shaped = shaper.line(1)
    for index in 0 ..< shaped.chunkCount { autoreleasepool { _ = shaper.ctLine(shaped, line: 1, chunk: index) } }
    #expect(shaped.chunkCount > 2000)
    #expect(shaped.shapedCount <= LineShaper.shapedChunksPerLine)
    // A measured line keeps only widths after measuring.
    let wide = try same(String(repeating: "\u{4E2D}", count: 40_000))
    let wideShaper = LineShaper(text: wide.a, metrics: TextMetrics(font: font11))
    let wideLine = wideShaper.line(0)
    _ = wideShaper.width(of: wideLine, line: 0)
    #expect(wideLine.isMeasured && wideLine.shapedCount <= LineShaper.shapedChunksPerLine)
}

// MARK: 2 and 8: copy

@MainActor
@Test func copyKeepsWholeCharactersWhenAnOffsetFallsInsideOne() throws {
    let model = try ComparisonModel.build(a: t("ab\n\u{1F600} hello\nend\n"), b: t("ab\n\u{1F600} hello\nend\n"),
                                          whitespace: .exact)
    let (view, _) = mkHost(model)
    view.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 0, offset: 1),
                                    head: TextPosition(row: 0, offset: 1)))
    view.moveCaret(by: 1)
    #expect(view.selection?.head == TextPosition(row: 1, offset: 0)) // not inside the surrogate pair
    view.setSelection(TextSelection(pane: .a, anchor: view.selection!.head, head: TextPosition(row: 2, offset: 3)))
    #expect(view.selectedText() == "\u{1F600} hello\nend")
    // An offset placed inside the pair directly still copies the line.
    view.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 1, offset: 1),
                                    head: TextPosition(row: 2, offset: 3)))
    #expect(view.selectedText() == "\u{1F600} hello\nend")
    // Clicks land on character boundaries too.
    let geometry = try #require(view.geometryA)
    for x in stride(from: 0.0, to: 30, by: 1.5) {
        let position = try #require(view.paneA.position(at: NSPoint(x: view.metrics.textInset + x,
                                                                    y: geometry.y(ofRow: 1) + 2)))
        #expect(position.offset != 1)
    }
}

@MainActor
@Test func copyIncludesALinesTerminatorExactlyWhenTheSelectionPassesIt() throws {
    let model = try ComparisonModel.build(a: t("one\ntwo\n"), b: t("one\ntwo\n"), whitespace: .exact)
    let (view, _) = mkHost(model)
    view.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 0, offset: 0), head: TextPosition(row: 1, offset: 0)))
    #expect(view.selectedText() == "one\n")
    view.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 1, offset: 0), head: TextPosition(row: 2, offset: 0)))
    #expect(view.selectedText() == "two\n")
    view.selectAllText()
    #expect(view.selectedText() == "one\ntwo\n")
    // Without a final newline the last line copies without one.
    let open = try ComparisonModel.build(a: t("one\ntwo"), b: t("one\ntwo"), whitespace: .exact)
    let (openView, _) = mkHost(open)
    openView.selectAllText()
    #expect(openView.selectedText() == "one\ntwo")
    // A line followed by Blocks padding: the padding adds nothing.
    let padded = try ComparisonModel.build(a: t("one\ntwo\nthree\n"), b: t("one\ntwo\nNEW\nthree\n"), whitespace: .exact)
    let (paddedView, _) = mkHost(padded)
    #expect(paddedView.geometryA!.rows.content(2) == .spacer(block: 1, top: true, bottom: true))
    paddedView.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 1, offset: 0),
                                          head: TextPosition(row: 2, offset: 0)))
    #expect(paddedView.selectedText() == "two\n")
    paddedView.setSelection(TextSelection(pane: .a, anchor: TextPosition(row: 1, offset: 0),
                                          head: TextPosition(row: 3, offset: 0)))
    #expect(paddedView.selectedText() == "two\n")
}

@MainActor
@Test func tripleClickSelectsTheLineWithItsTerminator() throws {
    let model = try ComparisonModel.build(a: t("one\ntwo\n"), b: t("one\ntwo\n"), whitespace: .exact)
    let (view, window) = mkHost(model)
    let geometry = try #require(view.geometryA)
    for row in [0, 1] {
        let point = view.paneA.convert(NSPoint(x: view.metrics.textInset + 2, y: geometry.y(ofRow: row) + 2), to: nil)
        for clicks in 1 ... 3 {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: clicks, pressure: 1))
            view.paneA.mouseDown(with: event)
        }
        #expect(view.selectedText() == (row == 0 ? "one\n" : "two\n"))
    }
}

// MARK: 5: highlights inside a long range

@MainActor
@Test func wordHighlightShowsInTheMiddleOfALongRange() throws {
    let a = "start " + String(repeating: "a", count: 12000) + " end\n"
    let b = "start " + String(repeating: "b", count: 12000) + " end\n"
    let model = try ComparisonModel.build(a: t("x\n" + a + "y\n"), b: t("x\n" + b + "y\n"), whitespace: .exact)
    let (view, _) = mkHost(model)
    let shaper = try #require(view.shaper(for: .a))
    let shaped = shaper.line(1)
    #expect(shaped.chunkCount > 4 && shaped.words.contains { $0.count >= 12000 })
    let geometry = try #require(view.geometryA)
    let y = geometry.y(ofRow: try #require(geometry.rows.row(ofLine: 1, side: .a)))
    let cw = view.metrics.charWidth
    func colour(atColumn column: CGFloat) -> NSColor {
        // The gap between two glyphs' ink: sample at the top of the row.
        let rect = NSRect(x: view.metrics.textInset + column * cw, y: y, width: 40 * cw, height: view.metrics.lineHeight)
        let rep = view.paneA.bitmapImageRepForCachingDisplay(in: rect)!
        view.paneA.cacheDisplay(in: rect, to: rep)
        return rep.colorAt(x: 1, y: 1)!
    }
    let nearStart = colour(atColumn: 10), middle = colour(atColumn: 6000)
    #expect(nearStart.usingColorSpace(.sRGB) == middle.usingColorSpace(.sRGB),
            "highlight at the start \(nearStart), in the middle \(middle)")
    #expect(middle.usingColorSpace(.sRGB) != NSColor.white.usingColorSpace(.sRGB))
}

@MainActor
@Test func findMatchesInsideLongLinesAreDrawnWhereverTheViewIs() throws {
    let line = String(repeating: "x", count: 9000) + "needle" + String(repeating: "y", count: 9000)
    let model = try same(line)
    let (view, _) = mkHost(model)
    let shaper = try #require(view.shaper(for: .a))
    let shaped = shaper.line(0)
    let match = 9000 ..< 9006
    let x = shaper.x(ofOffset: match.lowerBound, in: shaped, line: 0)
    let rough = shaper.roughRange(match.lowerBound, match.upperBound, in: shaped, line: 0)
    #expect(rough.contains(x))
    // A range spanning several chunks overlaps a view in its middle.
    let wide = shaper.roughRange(10, 17_000, in: shaped, line: 0)
    #expect(wide.contains(8000 * view.metrics.charWidth))
}

// MARK: 6: find offsets after a leading U+FEFF

@Test func findOffsetsCountALeadingByteOrderMark() throws {
    let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("ab name\nname\n".utf8)
    let model = try ComparisonModel.build(a: LoadedText(bytes: bytes, encodingName: "UTF-8", isLossy: false),
                                          b: t("q\n"), whitespace: .exact)
    let matches = FindEngine.search(model.a, side: .a, query: "name")
    #expect(matches.count == 2)
    #expect(matches.first?.range == 4 ..< 8)
    #expect(matches.last?.line == 1 && matches.last?.range == 0 ..< 4)
    let text = model.a.text(ofLine: 0) as NSString
    #expect(text.substring(with: NSRange(location: 4, length: 4)) == "name")
}

// MARK: 3: find steps are cheap with many matches

@MainActor
@Test func findStepsWithManyMatchesStayCheap() async throws {
    let source = UTF8TextSource()
    let model = try ComparisonModel.build(a: source.load(Corpus.fixture("text/big_a.txt")),
                                          b: source.load(Corpus.fixture("text/big_b.txt")), whitespace: .exact)
    let (view, _) = mkHost(model)
    let find = FindController(view: view)
    find.show()
    find.find("e")
    let deadline = ContinuousClock.now + .seconds(120)
    while find.isSearching, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(find.active.count > 100_000)
    // The overview gets at most one tick per pixel row.
    let ticks = (view.overviewB.marks.filter { $0.kind == .match }).count
    #expect(ticks <= max(Int(view.overviewB.bounds.height), 200))
    var times: [Double] = []
    for _ in 0 ..< 9 {
        let start = DispatchTime.now().uptimeNanoseconds
        find.next()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    times.sort()
    #expect(times[times.count / 2] < 8, "find step ms: \(times)")
    #expect(view.findHighlights.current == find.active[find.current!])
}
