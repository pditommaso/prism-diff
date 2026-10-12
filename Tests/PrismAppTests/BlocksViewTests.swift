// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismTestSupport
import Testing
@testable import PrismApp

@MainActor
private func makeView(_ a: String, _ b: String, size: NSSize = NSSize(width: 1200, height: 700)) throws
    -> (BlocksDiffView, NSWindow) {
    _ = NSApplication.shared
    let source = UTF8TextSource()
    let model = try ComparisonModel.build(a: source.load(Corpus.fixture("text/\(a)")),
                                          b: source.load(Corpus.fixture("text/\(b)")), whitespace: .exact)
    let view = BlocksDiffView(font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                              theme: BuiltinThemes.multicolorLight)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                          backing: .buffered, defer: true)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.show(model)
    return (view, window)
}

@MainActor
@Test func navigationStepsThroughChangesAndWraps() throws {
    let (view, _) = try makeView("a.swift", "b.swift")
    var reported: [Int?] = []
    view.onSelectionChange = { reported.append($0) }
    #expect(view.selectedChange == 0)
    view.selectNextChange()
    view.selectNextChange()
    view.selectNextChange()
    #expect(view.selectedChange == 3)
    #expect(reported == [1, 2, 3])
    for _ in 0 ..< 4 { view.selectNextChange() }
    #expect(view.selectedChange == 7)
    view.selectNextChange()
    #expect(view.selectedChange == 0)
    view.selectPreviousChange()
    #expect(view.selectedChange == 7)
}

@MainActor
@Test func clickingARowSelectsItsChange() throws {
    let (view, _) = try makeView("a.swift", "b.swift")
    let layout = try #require(view.model?.layout)
    let rows = layout.rows(ofChange: 5)
    view.selectChange(atRow: rows.lowerBound)
    #expect(view.selectedChange == 5)
    // An unchanged row keeps the selection.
    view.selectChange(atRow: 0)
    #expect(view.selectedChange == 5)
    #expect(view.isSelected(block: layout.changes[5]))
}

@MainActor
@Test func jumpingCentersTheChangeAndKeepsBothPanesAtTheSameOrigin() throws {
    let (view, _) = try makeView("big_a.txt", "big_b.txt")
    // A horizontal offset left over from scrolling must not survive a jump.
    view.scrollB.contentView.scroll(to: NSPoint(x: 40, y: 1000))
    view.scrollB.reflectScrolledClipView(view.scrollB.contentView)
    #expect(view.scrollA.contentView.bounds.origin == view.scrollB.contentView.bounds.origin)
    view.selectChange(472, scroll: true)
    let a = view.scrollA.contentView.bounds, b = view.scrollB.contentView.bounds
    #expect(a.origin == b.origin)
    #expect(a.minX == 0)
    let rows = try #require(view.model?.layout.rows(ofChange: 472))
    let middle = (view.metrics.y(ofRow: rows.lowerBound) + view.metrics.y(ofRow: rows.upperBound)) / 2
    #expect(abs(middle - a.midY) <= view.metrics.lineHeight)
    #expect(view.visibleAlignmentError() == 0)
    #expect(view.paneA.frame.size == view.paneB.frame.size)
}

@MainActor
@Test func fontChangesKeepTheTopRow() throws {
    let (view, _) = try makeView("big_a.txt", "big_b.txt")
    view.scroll(toY: view.metrics.y(ofRow: 5000) - view.metrics.topInset)
    let before = view.metrics.row(atY: view.scrollY + view.metrics.topInset)
    view.setFont(.monospacedSystemFont(ofSize: 16, weight: .regular))
    let after = view.metrics.row(atY: view.scrollY + view.metrics.topInset)
    #expect(abs(before - after) <= 1)
    #expect(view.visibleAlignmentError() == 0)
}

/// Waits (up to 90 s: other tests may keep the main actor busy) for a
/// comparison window to finish loading.
@MainActor
private func waitForLoad(_ controller: ComparisonWindowController) async throws {
    let deadline = ContinuousClock.now + .seconds(90)
    while controller.isLoading, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Test func comparisonWindowLoadsOffTheMainThread() async throws {
    _ = NSApplication.shared
    let controller = ComparisonWindowController(a: Corpus.fixture("text/a.swift"),
                                                b: Corpus.fixture("text/b.swift"))
    // Loaded without showing the window: another test closes every
    // visible window.
    controller.reload()
    #expect(controller.isLoading)
    try await waitForLoad(controller)
    #expect(!controller.isLoading)
    #expect(controller.bottomBar.changeLabel.stringValue == "Change 1 of 8")
    #expect(controller.tabStrip.titleField.stringValue == "a.swift | b.swift")
    controller.selectNextChange(nil)
    #expect(controller.bottomBar.changeLabel.stringValue == "Change 2 of 8")

    controller.swapSides(nil)
    try await waitForLoad(controller)
    #expect(controller.tabStrip.titleField.stringValue == "b.swift | a.swift")
    #expect(controller.bottomBar.changeLabel.stringValue == "Change 1 of 8")
    // The first change is now a deletion from the left side.
    let model = try #require(controller.blocksView.model)
    #expect(model.layout.blocks[model.layout.changes[0]].isDelete)
}

@MainActor
@Test func missingFileShowsAMessage() async throws {
    _ = NSApplication.shared
    let controller = ComparisonWindowController(a: Corpus.fixture("text/a.swift"),
                                                b: URL(filePath: "/nonexistent/prism-missing.txt"))
    // Loaded without showing the window: another test closes every
    // visible window.
    controller.reload()
    try await waitForLoad(controller)
    #expect(controller.placeholder.message.contains("prism-missing.txt"))
}

@Test func builtinThemesDecodeAndRoundTrip() throws {
    #expect(BuiltinThemes.all.count == 4)
    #expect(Set(BuiltinThemes.all.map(\.id)).count == 4)
    #expect(BuiltinThemes.multicolorDark.dark && !BuiltinThemes.singleLight.dark)
    for theme in BuiltinThemes.all {
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(Theme.self, from: data) == theme)
    }
    // Single-colour themes share one family; multicolour ones do not.
    #expect(BuiltinThemes.singleLight.insert == BuiltinThemes.singleLight.change)
    #expect(BuiltinThemes.multicolorLight.insert != BuiltinThemes.multicolorLight.delete)
    #expect(ThemeChoice.theme(dark: true, singleColor: false).id == "multicolor-dark")
    #expect(ThemeChoice.theme(dark: false, singleColor: true).id == "single-light")
}

@Test func themeColorsParseHex() throws {
    let color = try #require(ThemeColor(hex: "#FF800040"))
    #expect(color.red == 1 && abs(color.green - 128.0 / 255) < 1e-9 && color.blue == 0)
    #expect(abs(color.alpha - 64.0 / 255) < 1e-9)
    #expect(color.hex == "#FF800040")
    #expect(ThemeColor(hex: "#123456")?.alpha == 1)
    #expect(ThemeColor(hex: "123456") == nil)
    #expect(ThemeColor(hex: "#12345") == nil)
    #expect(throws: (any Error).self) { try Theme.decode(#"{"id": 1}"#) }
    let block = DiffBlock(kind: .insert, a: 3 ..< 3, b: 3 ..< 5)
    #expect(BuiltinThemes.multicolorLight.colors(for: block) == BuiltinThemes.multicolorLight.insert)
    #expect(BuiltinThemes.multicolorLight.colors(for: DiffBlock(kind: .equal, a: 0 ..< 1, b: 0 ..< 1)) == nil)
}

@MainActor
@Test func metricsMapRowsAndPoints() {
    let metrics = TextMetrics(font: .monospacedSystemFont(ofSize: 11, weight: .regular))
    #expect(metrics.lineHeight == metrics.lineHeight.rounded())
    #expect(metrics.row(atY: metrics.y(ofRow: 42)) == 42)
    #expect(metrics.row(atY: metrics.y(ofRow: 42) + metrics.lineHeight - 0.01) == 42)
    #expect(metrics.rows(in: 0, metrics.y(ofRow: 3), rowCount: 10) == 0 ..< 4)
    #expect(metrics.rows(in: metrics.y(ofRow: 20), metrics.y(ofRow: 30), rowCount: 10).isEmpty)
    #expect(metrics.gutterWidth(maxNumber: 100_000) > metrics.gutterWidth(maxNumber: 9))
}

@MainActor
@Test func textSettingsPersistAndPickTheTheme() throws {
    let suite = "prism.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = TextSettings(defaults: defaults)
    #expect(settings.font.pointSize == 11)
    #expect(TextSettings.describe(settings.font) == "System Monospaced \u{2013} 11 pt")
    #expect(settings.theme.id == "multicolor-light")
    settings.dark = true
    settings.singleColor = true
    #expect(settings.theme.id == "single-dark")
    let menlo = try #require(NSFont(name: "Menlo-Regular", size: 14))
    settings.font = menlo
    #expect(settings.font.fontName == "Menlo-Regular" && settings.font.pointSize == 14)
    settings.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    #expect(defaults.string(forKey: TextSettings.Key.fontName) == nil)
    #expect(settings.font.pointSize == 12)
    settings.ignoreWhitespace = true
    #expect(TextSettings(defaults: defaults).ignoreWhitespace)
}
