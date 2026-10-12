// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Darwin
import FolderCore
import PrismIntegration
import PrismProtocol
import PrismTestSupport
import Testing
@testable import PrismApp

// M11 accessibility audit, headless: every scope's window is built
// offscreen and its accessibility hierarchy walked the way VoiceOver
// sees it. No window is ever shown. scripts/accept/a11y-audit.sh runs
// these tests.

// MARK: helpers

@MainActor
private func spin(until condition: () -> Bool, timeout: TimeInterval = 30) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Lays the window out at a usual size, as if it were on screen.
@MainActor
private func layOut(_ window: NSWindow?) throws -> NSView {
    let window = try #require(window)
    window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
    window.layoutIfNeeded()
    window.displayIfNeeded()
    return try #require(window.contentView)
}

/// Every interactive element under the window's content has a name.
@MainActor
private func expectAllLabeled(_ window: NSWindow?, _ scope: String, minimum: Int = 1,
                              allowing allowed: Set<NSAccessibility.Role> = [],
                              sourceLocation: SourceLocation = #_sourceLocation) throws -> [AccessibilityAudit.Element] {
    let content = try layOut(window)
    let elements = AccessibilityAudit.walk(content)
    let interactive = elements.filter(\.isInteractive)
    let unlabeled = interactive.filter { !$0.isLabeled && !allowed.contains($0.role) }
    #expect(unlabeled.isEmpty, "\(scope): unlabeled \(unlabeled.map(\.description))", sourceLocation: sourceLocation)
    #expect(interactive.count >= minimum, "\(scope): only \(interactive.count) interactive elements",
            sourceLocation: sourceLocation)
    return elements
}

private func names(_ elements: [AccessibilityAudit.Element]) -> Set<String> {
    Set(elements.compactMap(\.name))
}

private func folderFixture() throws -> TemporaryDirectory {
    let directory = try TemporaryDirectory(prefix: "prism-a11y-folders")
    let source = Corpus.directory.appending(path: "fixtures/folders", directoryHint: .isDirectory)
    for side in ["left", "right"] {
        try FileManager.default.copyItem(at: source.appending(path: side),
                                         to: directory.url.appending(path: side, directoryHint: .isDirectory))
    }
    return directory
}

private func mergeFiles(_ directory: TemporaryDirectory) throws -> MergeFiles {
    for file in ["a.txt", "b.txt", "base.txt"] {
        try FileManager.default.copyItem(at: Corpus.directory.appending(path: "merge/notes/\(file)"),
                                         to: directory.url.appending(path: file))
    }
    return MergeFiles(a: directory.url.appending(path: "a.txt"), b: directory.url.appending(path: "b.txt"),
                      base: directory.url.appending(path: "base.txt"), output: directory.url.appending(path: "out.txt"))
}

@MainActor
private func textWindow() async throws -> (DocumentWindowController, TextTab) {
    _ = NSApplication.shared
    let controller = DocumentWindowController()
    let tab = TextTab(a: Corpus.fixture("text/a.swift"), b: Corpus.fixture("text/b.swift"), key: "a11y", title: nil)
    controller.insert(tab, at: 0)
    #expect(await spin { tab.controller.blocksView.model != nil })
    return (controller, tab)
}

// MARK: - VoiceOver: no unlabeled controls in any scope

@MainActor
@Suite(.serialized) struct AccessibilityAuditTests {
    @Test func launchWindowIsANamedButton() throws {
        _ = NSApplication.shared
        let controller = DocumentWindowController()
        defer { controller.close() }
        let launch = LaunchTab()
        controller.insert(launch, at: 0)
        let elements = try expectAllLabeled(controller.window, "launch")
        let button = try #require(elements.first { $0.identifier == "prism.launch" })
        #expect(button.role == .button && button.name == LaunchDropView.dropCaption)
        #expect(launch.dropView.accessibilityHelp()?.isEmpty == false)
    }

    @Test func titleBarNamesTheAppNotTheComparison() async throws {
        let (controller, tab) = try await textWindow()
        defer { controller.close() }
        controller.insert(LaunchTab(), at: 1)
        for index in [0, 1, 0] {
            controller.selectTab(index)
            #expect(controller.window?.title == PrismWindowTitle.default)
        }
        #expect(controller.window?.accessibilityLabel() == tab.title)
    }

    @Test func textScopeWithFindBarShelfAndTabs() async throws {
        let (controller, tab) = try await textWindow()
        defer { controller.close() }
        controller.insert(LaunchTab(), at: 1)
        controller.selectTab(0)
        tab.controller.showFindBar(nil)
        tab.controller.setShelfFiles([Corpus.fixture("text/a.swift"), Corpus.fixture("text/b.swift"),
                                      Corpus.fixture("text/big_a.txt")].map { ShelfEntry(url: $0) }, a: 0, b: 1)
        #expect(tab.controller.isShelfVisible)
        for mode in [ViewMode.blocks, .fluid, .unified] {
            tab.controller.setMode(mode, remember: false)
            let elements = try expectAllLabeled(controller.window, "text \(mode)", minimum: 20)
            let all = names(elements)
            // Tab strip, breadcrumbs, merge arrows, find bar and shelf.
            for expected in ["Comparisons", "a.swift | b.swift", "3 files", "Add Tab", "fixtures", "a.swift", "b.swift",
                             "Swap A and B", "Toggle File Shelf", "Layout", "Merge", "Copy to the right",
                             "Copy to the left", "Previous change", "Next change", "Ignore whitespace", "Find",
                             "Previous Match", "Next Match", "File Shelf", "Add Files", "A text"] {
                #expect(all.contains(expected), "text \(mode): no element named \(expected)")
            }
            // Unified searches its single text: no A/B choice there.
            #expect(all.contains("Search In") == (mode != .unified))
            // Decorations stay out of the way: no chevrons between the
            // path components, no icons repeating a tab's title.
            #expect(!elements.contains { $0.role == .image && $0.path.contains("prism.path") })
            #expect(!elements.contains { $0.role == .image && $0.path.contains("prism.tab.") })
            #expect(!elements.contains { $0.role == .staticText && $0.path.contains("prism.tab.") })
        }
        // The tab carries its state and its actions.
        let item = try #require(controller.tabStrip.items.first)
        #expect(item.accessibilityRole() == .radioButton && item.accessibilityValue() as? Int == 1)
        #expect(item.accessibilityCustomActions()?.map(\.name).contains("Close Tab") == true)
    }

    @Test func breadcrumbComponentsAreNamedAfterTheirFolders() throws {
        _ = NSApplication.shared
        let bar = BreadcrumbView(frame: NSRect(x: 0, y: 0, width: 2000, height: 22))
        bar.show(URL(filePath: "/Users/someone/Projects/notes.txt"), display: .path)
        bar.layoutSubtreeIfNeeded()
        let buttons = AccessibilityAudit.walk(bar).filter { $0.role == .button }
        #expect(buttons.dropFirst().map(\.name) == ["Users", "someone", "Projects", "notes.txt"])
        #expect(AccessibilityAudit.walk(bar).allSatisfy { $0.role != .image })
    }

    @Test func folderScopeNamesTablesAndEveryGutterButton() async throws {
        _ = NSApplication.shared
        let fixture = try folderFixture()
        defer { fixture.remove() }
        let controller = DocumentWindowController(left: fixture.url.appending(path: "left"),
                                                  right: fixture.url.appending(path: "right"))
        defer { controller.close() }
        let tab = try #require(controller.selectedTab as? FolderTab)
        #expect(await spin { tab.scope.level?.isComplete == true })
        let elements = try expectAllLabeled(controller.window, "folder", minimum: 12)
        let all = names(elements)
        for expected in ["Folder A", "Folder B", "Copy directions", "Copy to Right", "Copy to Left", "Copy",
                         "Comparisons", "left | right"] {
            #expect(all.contains(expected), "folder: no element named \(expected)")
        }
        let stage = elements.filter { $0.identifier?.hasPrefix("prism.folder.stage.") == true }
        #expect(!stage.isEmpty)
        for button in stage {
            let name = try #require(button.identifier?.dropFirst("prism.folder.stage.".count))
            #expect(button.name == "Copy direction for \(name)")
            #expect((button.object as? NSAccessibilityProtocol)?.accessibilityValue() as? String != nil)
        }
        #expect(elements.contains { $0.role == .checkBox && $0.name?.hasSuffix("Changed") == true })
    }

    @Test func changesetScopeNamesTheFileList() throws {
        _ = NSApplication.shared
        let a = Corpus.fixture("text/a.swift").path, b = Corpus.fixture("text/b.swift").path
        let document = DocumentContent(
            id: "doc-a11y", kind: .partialChangeset, title: "Changes in repo", tool: .git,
            entries: [ChangesetEntry(relativePath: "one.swift", status: .changed, files: [
                ComparisonFile(originalPath: a, path: a, isSnapshot: true),
                ComparisonFile(originalPath: b, path: b, isSnapshot: false),
            ])], isComplete: false)
        let controller = ChangesetWindowController(document: document)
        defer { controller.close() }
        let elements = try expectAllLabeled(controller.window, "changeset", minimum: 8)
        #expect(names(elements).contains("Changed files"))
    }

    @Test func mergeScopeReadsLinesWithTheirConflictState() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(prefix: "prism-a11y-merge")
        defer { directory.remove() }
        let controller = MergeWindowController(files: try mergeFiles(directory))
        defer { controller.close() }
        controller.load()
        #expect(await spin { !controller.isLoading })
        for mode in [ViewMode.unified, .blocks, .fluid] {
            controller.setMode(mode)
            let elements = try expectAllLabeled(controller.window, "merge \(mode)", minimum: 8)
            let all = names(elements)
            for expected in ["Layout", "Merge", "Copy to the right", "Copy to the left", "Next change"] {
                #expect(all.contains(expected), "merge \(mode): no element named \(expected)")
            }
            let lines = elements.filter { $0.role == .staticText && $0.object is LineAccessibilityElement }
            #expect(lines.contains { $0.name?.hasPrefix("Result line") == true })
            #expect(lines.contains { $0.name?.hasSuffix(", conflict") == true })
            #expect(lines.contains { $0.name?.hasPrefix("A line") == true })
            #expect(lines.contains { $0.name?.hasPrefix("B line") == true || $0.name?.contains(", B line") == true })
        }
    }

    @Test func mergeLineDescriptions() {
        var display = MergeDisplay()
        display.linesA = ["one", "two"]
        display.linesB = ["one", "TWO"]
        display.regions = [
            .init(kind: .equal, shape: .change, resolved: false, a: 0 ..< 1, b: 0 ..< 1, output: ["one"],
                  placeholder: false, outputStart: 0),
            .init(kind: .conflict, shape: .change, resolved: false, a: 1 ..< 2, b: 1 ..< 2, output: [""],
                  placeholder: true, outputStart: 1),
        ]
        let a = MergeCanvas.describe(MergeRow(content: .line(.a, 1, number: 2, numberB: nil), region: 1), display: display)
        #expect(a?.label == "A line 2, conflict" && a?.value == "two")
        let b = MergeCanvas.describe(MergeRow(content: .line(.b, 1, number: nil, numberB: 2), region: 1), display: display)
        #expect(b?.label == "B line 2, conflict" && b?.value == "TWO")
        let both = MergeCanvas.describe(MergeRow(content: .line(.a, 0, number: 1, numberB: 1), region: 0), display: display)
        #expect(both?.label == "A line 1, B line 1" && both?.value == "one")
        let hole = MergeCanvas.describe(MergeRow(content: .placeholder(number: 2), region: 1), display: display)
        #expect(hole?.label == "Result line 2, conflict" && hole?.value == "unresolved")
        #expect(MergeCanvas.describe(MergeRow(content: .filler, region: 1), display: display) == nil)
        display.regions[1].resolved = true
        let resolved = MergeCanvas.describe(MergeRow(content: .line(.output, 1, number: 2, numberB: nil), region: 1),
                                            display: display)
        #expect(resolved?.label == "Result line 2, resolved conflict")
    }

    @Test func integrationSettingsAboutAndHelpWindows() throws {
        _ = NSApplication.shared
        let integration = IntegrationWindowController()
        defer { integration.close() }
        // The "Install in:" pop-up (shown when several folders qualify) is
        // named once the CLI rework lands in the Integration window (a
        // file this branch leaves alone meanwhile).
        _ = try expectAllLabeled(integration.window, "integration", allowing: [.popUpButton])
        let settings = SettingsWindowController()
        defer { settings.close() }
        let settingsElements = try expectAllLabeled(settings.window, "settings", minimum: 5)
        #expect(names(settingsElements).contains("Text background"))
        let about = AboutWindowController()
        defer { about.close() }
        let aboutElements = try expectAllLabeled(about.window, "about")
        #expect(names(aboutElements).contains("Prism icon"))
        let help = HelpWindowController(topics: HelpBook.topics(menu: MainMenuBuilder.make(target: NSObject())))
        defer { help.close() }
        let helpElements = try expectAllLabeled(help.window, "help", minimum: 3)
        #expect(names(helpElements).isSuperset(of: ["Search Help", "Help Topics", "Help: Welcome to Prism"]))
    }

    /// The audit itself catches what it should.
    @Test func auditFlagsAnUnnamedButton() {
        _ = NSApplication.shared
        let group = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let unnamed = NSButton(image: NSImage(size: NSSize(width: 8, height: 8)), target: nil, action: nil)
        let named = NSButton(title: "Go", target: nil, action: nil)
        group.addSubview(unnamed)
        group.addSubview(named)
        #expect(AccessibilityAudit.unlabeled(in: group).count == 1)
        unnamed.setAccessibleName("Refresh")
        #expect(AccessibilityAudit.unlabeled(in: group).isEmpty)
    }

    // MARK: - keyboard

    @Test func launchWindowTakesTheKeyboard() throws {
        _ = NSApplication.shared
        let controller = DocumentWindowController()
        defer { controller.close() }
        let launch = LaunchTab()
        controller.insert(launch, at: 0)
        #expect(launch.initialFirstResponder === launch.dropView)
        #expect(launch.dropView.acceptsFirstResponder && launch.dropView.canBecomeKeyView)
        #expect(controller.window?.firstResponder === launch.dropView)
        var clicks = 0
        launch.dropView.onClick = { clicks += 1 }
        for code: UInt16 in [36, 76, 49] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: " ",
                                                      charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code))
            launch.dropView.keyDown(with: event)
        }
        #expect(clicks == 3)
    }

    @Test func selectingATabFocusesItsContent() async throws {
        let (controller, tab) = try await textWindow()
        defer { controller.close() }
        let fixture = try folderFixture()
        defer { fixture.remove() }
        let document = FolderDocument(left: fixture.url.appending(path: "left"), right: fixture.url.appending(path: "right"))
        let folder = document.makeTab(relativePath: "")
        controller.insert(folder, at: 1)
        #expect(controller.window?.firstResponder === folder.scope.view.tableA)
        controller.selectTab(0)
        #expect(controller.window?.firstResponder is PaneTextView)
        #expect(tab.initialFirstResponder is PaneTextView)
    }

    /// Tab moves through the controls of the selected tab: the key view
    /// loop reaches the text, the find field and the bottom bar.
    @Test func keyViewLoopReachesEveryControl() async throws {
        let (controller, tab) = try await textWindow()
        defer { controller.close() }
        tab.controller.showFindBar(nil)
        let window = try #require(controller.window)
        #expect(window.autorecalculatesKeyViewLoop)
        _ = try layOut(window)
        window.recalculateKeyViewLoop()
        var seen: [NSView] = []
        var view: NSView? = window.contentView
        while let current = view, !seen.contains(where: { $0 === current }), seen.count < 500 {
            seen.append(current)
            view = current.nextKeyView
        }
        func reached(_ target: NSView) -> Bool { seen.contains { $0 === target } }
        let blocks = tab.controller.blocksView
        #expect(reached(blocks.paneA))
        #expect(reached(tab.controller.find.bar.field))
        let bottom = tab.controller.bottomBar
        #expect(reached(bottom.layoutControl) && reached(bottom.nextButton))
        // Top to bottom: the find field comes before the text, the text
        // before the bottom bar.
        let order = { (target: NSView) in seen.firstIndex { $0 === target } ?? .max }
        #expect(order(tab.controller.find.bar.field) < order(blocks.paneA))
        #expect(order(blocks.paneA) < order(bottom.layoutControl))
    }

    @Test func essentialCommandsHaveShortcuts() {
        let menu = MainMenuBuilder.make(target: NSObject())
        let shortcuts = HelpBook.shortcuts(from: menu).blocks.compactMap { block -> String? in
            if case let .shortcut(title, _) = block { return title }
            return nil
        }
        for command in ["New Window", "New Tab", "Open...", "Close Comparison", "Save", "Find\u{2026}", "Find Next",
                        "Next Change", "Previous Change", "Next Conflict", "Previous Conflict", "Copy to Right",
                        "Copy to Left", "Reset Selection", "Blocks", "Fluid", "Unified", "Toggle File Shelf",
                        "Select Next Tab", "Select Previous Tab", "Start Copying Files", "Swap A & B",
                        "Prism Help"] {
            #expect(shortcuts.contains(command), "\(command) has no shortcut")
        }
    }
}

// MARK: - Increase Contrast and Reduce Motion

@MainActor
@Suite(.serialized) struct DisplayOptionsTests {
    @Test func contrastedThemesStandOutMore() {
        for theme in BuiltinThemes.all {
            let strong = theme.contrasted()
            #expect(strong.isContrasted && !theme.isContrasted)
            for (normal, contrasted) in [(theme.insert, strong.insert), (theme.delete, strong.delete),
                                         (theme.change, strong.change)] {
                for (a, b) in [(normal.band, contrasted.band), (normal.word, contrasted.word),
                               (normal.border, contrasted.border), (normal.gutter, contrasted.gutter)] {
                    #expect(ThemeColor.contrast(b, theme.background) > ThemeColor.contrast(a, theme.background),
                            "\(theme.id): \(a.hex) -> \(b.hex)")
                }
            }
            #expect(strong.equalText == theme.text)
            // Line numbers may be translucent: compare them as drawn.
            func drawn(_ color: ThemeColor) -> ThemeColor { theme.background.mixed(with: color, color.alpha) }
            #expect(ThemeColor.contrast(drawn(strong.lineNumber), theme.background)
                    > ThemeColor.contrast(drawn(theme.lineNumber), theme.background))
        }
    }

    @Test func textSettingsFollowIncreaseContrast() {
        let defaults = UserDefaults(suiteName: "prism-a11y-\(UUID().uuidString)")!
        let settings = TextSettings(defaults: defaults)
        DisplayOptions.increaseContrastOverride = true
        defer { DisplayOptions.increaseContrastOverride = nil }
        #expect(settings.theme.isContrasted)
        let palette = ThemePalette(settings.theme)
        #expect(palette.findMatchBorder == settings.theme.text.cgColor)
        DisplayOptions.increaseContrastOverride = false
        #expect(!settings.theme.isContrasted)
        #expect(ThemePalette(settings.theme).findMatchBorder != settings.theme.text.cgColor)
    }

    @Test func openComparisonsSwitchThemeWhenTheSettingChanges() async throws {
        let (controller, tab) = try await textWindow()
        defer { controller.close() }
        DisplayOptions.increaseContrastOverride = true
        defer { DisplayOptions.increaseContrastOverride = nil }
        DisplayOptions.displayOptionsChanged()
        #expect(tab.controller.blocksView.theme.isContrasted)
        DisplayOptions.increaseContrastOverride = false
        DisplayOptions.displayOptionsChanged()
        #expect(!tab.controller.blocksView.theme.isContrasted)
    }

    @Test func conflictAndFolderColoursStrengthen() {
        for dark in [false, true] {
            let normal = ConflictPalette(dark: dark), strong = ConflictPalette(dark: dark, increaseContrast: true)
            #expect(normal.band != strong.band && normal.border != strong.border && normal.word != strong.word)
        }
        let appearance = NSAppearance(named: .aqua)!
        func components(_ color: NSColor?) -> [CGFloat] {
            var result: [CGFloat] = []
            appearance.performAsCurrentDrawingAppearance {
                let c = color?.usingColorSpace(.sRGB)
                result = [c?.redComponent ?? -1, c?.greenComponent ?? -1, c?.blueComponent ?? -1]
            }
            return result
        }
        for status in [RowStatus.changed, .leftOnly, .rightOnly] {
            let pale = components(FolderColors.background(status, increaseContrast: false))
            let strong = components(FolderColors.background(status, increaseContrast: true))
            // Light rows get darker: further from the white background.
            #expect(strong.reduce(0, +) < pale.reduce(0, +), "\(status)")
            #expect(components(FolderColors.accent(status, increaseContrast: true)).reduce(0, +)
                    < components(FolderColors.accent(status, increaseContrast: false)).reduce(0, +))
        }
        #expect(FolderColors.background(.unchanged, increaseContrast: true) == nil)
    }

    @Test func reduceMotionTurnsWindowAnimationsOff() {
        _ = NSApplication.shared
        DisplayOptions.reduceMotionOverride = true
        defer { DisplayOptions.reduceMotionOverride = nil }
        let controller = DocumentWindowController()
        defer { controller.close() }
        #expect(controller.window?.animationBehavior == NSWindow.AnimationBehavior.none)
        DisplayOptions.reduceMotionOverride = false
        DisplayOptions.displayOptionsChanged()
        #expect(controller.window?.animationBehavior == .default)
    }

    /// Moving to a change scrolls at once (nothing is animated, so Reduce
    /// Motion has nothing to stop).
    @Test func goingToAChangeScrollsImmediately() async throws {
        _ = NSApplication.shared
        let controller = DocumentWindowController()
        defer { controller.close() }
        let tab = TextTab(a: Corpus.fixture("text/big_a.txt"), b: Corpus.fixture("text/big_b.txt"), key: "big", title: nil)
        controller.insert(tab, at: 0)
        #expect(await spin { tab.controller.blocksView.model != nil })
        _ = try layOut(controller.window)
        DisplayOptions.reduceMotionOverride = true
        defer { DisplayOptions.reduceMotionOverride = nil }
        let blocks = tab.controller.blocksView
        let before = blocks.scrollY(of: .a)
        for _ in 0 ..< 5 { tab.controller.selectNextChange(nil) }
        let after = blocks.scrollY(of: .a)
        #expect(after != before)
        // Nothing left to animate: the position holds.
        try await Task.sleep(for: .milliseconds(300))
        #expect(blocks.scrollY(of: .a) == after)
    }

    /// No animation API in the app's sources (spinners aside), so every
    /// scroll and transition is immediate whatever Reduce Motion says.
    @Test func sourcesUseNoAnimations() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/PrismApp", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var files = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for pattern in [".animator()", "runAnimationGroup", "allowsImplicitAnimation = true", "NSViewAnimation",
                            "CABasicAnimation", "animates = true"] where text.contains(pattern) {
                offenders.append("\(url.lastPathComponent): \(pattern)")
            }
        }
        #expect(files > 50)
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
