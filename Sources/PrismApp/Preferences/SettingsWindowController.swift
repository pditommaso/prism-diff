// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// The Settings window. One pane for now, Text; more panes join the
/// toolbar as their features arrive.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let windowTitle = "Settings"

    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // Keep "Settings" as the title whichever pane is selected.
        tabs.canPropagateSelectedChildViewControllerTitle = false
        let text = NSTabViewItem(viewController: TextSettingsViewController())
        text.label = "Text"
        text.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Text")
        tabs.addTabViewItem(text)
        let folders = NSTabViewItem(viewController: FolderSettingsViewController())
        folders.label = "Folders"
        folders.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folders")
        tabs.addTabViewItem(folders)
        let window = NSWindow(contentViewController: tabs)
        window.title = Self.windowTitle
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        AppFocus.activate()
    }
}

/// Text pane: background, difference colouring, font, and the wrapping and
/// whitespace defaults for new comparisons.
@MainActor
final class TextSettingsViewController: NSViewController {
    private var settings = TextSettings()
    let backgroundControl = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne,
                                               target: nil, action: nil)
    let multicolorButton = NSButton(radioButtonWithTitle: "Multicolored", target: nil, action: nil)
    let singleColorButton = NSButton(radioButtonWithTitle: "Single Color", target: nil, action: nil)
    let fontField = NSTextField(labelWithString: "")
    let changeFontButton = NSButton(title: "Change\u{2026}", target: nil, action: nil)
    let ignoreWhitespaceButton = NSButton(checkboxWithTitle: "Ignore whitespace at line edges",
                                          target: nil, action: nil)
    let wrapLinesButton = NSButton(checkboxWithTitle: "Turn on Wrap Lines for new comparisons",
                                   target: nil, action: nil)

    override func loadView() {
        backgroundControl.target = self
        backgroundControl.action = #selector(backgroundChanged(_:))
        backgroundControl.setAccessibilityIdentifier("prism.settings.background")
        backgroundControl.setAccessibleName("Text background")
        for button in [multicolorButton, singleColorButton] {
            button.target = self
            button.action = #selector(coloringChanged(_:))
        }
        changeFontButton.target = self
        changeFontButton.action = #selector(showFontPanel(_:))
        ignoreWhitespaceButton.target = self
        ignoreWhitespaceButton.action = #selector(whitespaceChanged(_:))
        wrapLinesButton.target = self
        wrapLinesButton.action = #selector(wrapChanged(_:))
        wrapLinesButton.setAccessibilityIdentifier("prism.settings.wrapLines")
        fontField.lineBreakMode = .byTruncatingTail

        let coloring = NSStackView(views: [
            multicolorButton, hint("Insertions, deletions and changes each get their own color."),
            singleColorButton, hint("Every difference uses the same color."),
        ])
        coloring.orientation = .vertical
        coloring.alignment = .leading
        coloring.spacing = 4
        let fontRow = NSStackView(views: [fontField, changeFontButton])
        fontRow.spacing = 8
        let whitespace = NSStackView(views: [ignoreWhitespaceButton, hint("Applies to comparisons opened afterwards.")])
        whitespace.orientation = .vertical
        whitespace.alignment = .leading
        whitespace.spacing = 4

        let grid = NSGridView(views: [
            [label("Background:"), backgroundControl],
            [label("Difference colors:"), coloring],
            [label("Font:"), fontRow],
            [label("Layout:"), wrapLinesButton],
            [label("Whitespace:"), whitespace],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for row in 0 ..< grid.numberOfRows { grid.row(at: row).yPlacement = .top }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 480),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            fontField.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        view = container
        refresh()
        preferredContentSize = container.fittingSize
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    func refresh() {
        backgroundControl.selectedSegment = settings.dark ? 1 : 0
        multicolorButton.state = settings.singleColor ? .off : .on
        singleColorButton.state = settings.singleColor ? .on : .off
        let font = settings.font
        fontField.stringValue = TextSettings.describe(font)
        fontField.font = NSFontManager.shared.convert(font, toSize: NSFont.systemFontSize)
        ignoreWhitespaceButton.state = settings.ignoreWhitespace ? .on : .off
        wrapLinesButton.state = settings.wrapLines ? .on : .off
    }

    @objc func wrapChanged(_ sender: NSButton) {
        settings.wrapLines = sender.state == .on
    }

    @objc func backgroundChanged(_ sender: NSSegmentedControl) {
        settings.dark = sender.selectedSegment == 1
        refresh()
    }

    @objc func coloringChanged(_ sender: NSButton) {
        settings.singleColor = sender === singleColorButton
        refresh()
    }

    @objc func whitespaceChanged(_ sender: NSButton) {
        settings.ignoreWhitespace = sender.state == .on
    }

    @objc func showFontPanel(_ sender: Any?) {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(settings.font, isMultiple: false)
        manager.orderFrontFontPanel(sender)
    }

    /// Sent by the font panel.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        settings.font = sender.convert(settings.font)
        refresh()
    }
}
