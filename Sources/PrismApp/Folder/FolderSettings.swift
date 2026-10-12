// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import FolderCore

/// Folder comparison preferences, stored in the user defaults.
struct FolderSettings {
    static let didChange = Notification.Name("io.github.pditommaso.prism.folderSettingsDidChange")
    static let scanHiddenKey = "FolderScanHiddenFiles"
    static let compareContentsKey = "FolderCompareContents"
    static let showCopySummaryKey = "FolderShowCopySummary"
    static let warnOnAppBundlesKey = "FolderWarnOnAppBundles"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.shared) { self.defaults = defaults }

    /// Include hidden items (dot-files and items flagged hidden). Off by
    /// default; `.DS_Store` stays excluded either way.
    var scanHiddenFiles: Bool {
        get { defaults.bool(forKey: Self.scanHiddenKey) }
        nonmutating set { set(newValue, Self.scanHiddenKey) }
    }

    /// Confirm changed files by reading their contents. On by default:
    /// files that differ only in their modification date (a fresh checkout,
    /// a copy) are checked in the background and shown as unchanged.
    var compareContents: Bool {
        get { defaults.object(forKey: Self.compareContentsKey) as? Bool ?? true }
        nonmutating set { set(newValue, Self.compareContentsKey) }
    }

    /// Show the summary sheet before copying (Option skips it). On by
    /// default.
    var showCopySummary: Bool {
        get { defaults.object(forKey: Self.showCopySummaryKey) == nil || defaults.bool(forKey: Self.showCopySummaryKey) }
        nonmutating set { set(newValue, Self.showCopySummaryKey) }
    }

    /// Warn before staging copies inside an application bundle. On until
    /// the warning's "don't show again" box is checked.
    var warnOnAppBundles: Bool {
        get { defaults.object(forKey: Self.warnOnAppBundlesKey) == nil || defaults.bool(forKey: Self.warnOnAppBundlesKey) }
        nonmutating set { set(newValue, Self.warnOnAppBundlesKey) }
    }

    var options: FolderOptions {
        FolderOptions(includeHidden: scanHiddenFiles, compareContents: compareContents)
    }

    private func set(_ value: Bool, _ key: String) {
        guard defaults.bool(forKey: key) != value || defaults.object(forKey: key) == nil else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Settings ▸ Folders: hidden files and the content check.
@MainActor
final class FolderSettingsViewController: NSViewController {
    let hiddenButton = NSButton(checkboxWithTitle: "Show hidden files", target: nil, action: nil)
    let contentsButton = NSButton(checkboxWithTitle: "Compare file contents", target: nil, action: nil)
    let summaryButton = NSButton(checkboxWithTitle: "Show a summary before copying", target: nil, action: nil)

    override func loadView() {
        for button in [hiddenButton, contentsButton, summaryButton] {
            button.target = self
            button.action = #selector(changed(_:))
        }
        hiddenButton.setAccessibilityIdentifier("prism.settings.scanHidden")
        contentsButton.setAccessibilityIdentifier("prism.settings.compareContents")
        summaryButton.setAccessibilityIdentifier("prism.settings.copySummary")
        let hidden = column(hiddenButton, hint("Include items whose names start with a dot, and items marked hidden."))
        let contents = column(contentsButton,
                              hint("Read files whose dates differ but sizes match, so files that were only touched show as unchanged. Slower."))
        let summary = column(summaryButton, hint("List what will be copied and replaced, and ask before starting. Hold Option to skip it."))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Hidden files:"), hidden],
            [NSTextField(labelWithString: "Contents:"), contents],
            [NSTextField(labelWithString: "Copying:"), summary],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 480),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
        ])
        view = container
        refresh()
        preferredContentSize = container.fittingSize
    }

    private func column(_ button: NSButton, _ hint: NSTextField) -> NSStackView {
        let stack = NSStackView(views: [button, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 320
        return field
    }

    func refresh() {
        let settings = FolderSettings()
        hiddenButton.state = settings.scanHiddenFiles ? .on : .off
        contentsButton.state = settings.compareContents ? .on : .off
        summaryButton.state = settings.showCopySummary ? .on : .off
    }

    @objc func changed(_ sender: NSButton) {
        let settings = FolderSettings()
        if sender === hiddenButton { settings.scanHiddenFiles = sender.state == .on }
        if sender === contentsButton { settings.compareContents = sender.state == .on }
        if sender === summaryButton { settings.showCopySummary = sender.state == .on }
    }
}

/// Row colours of the folder tables, by status, for light and dark
/// appearance. Our own palette: red for left-only, green for right-only,
/// lavender for changed. With Increase Contrast, the row and arrow colours
/// move towards the strong (selected) colour of their status.
enum FolderColors {
    private typealias RGB = (Int, Int, Int)

    /// Light and dark strong colours of each status.
    private static func strong(_ status: RowStatus) -> (light: RGB, dark: RGB)? {
        switch status {
        case .unchanged: return nil
        case .leftOnly: return ((0xC8, 0x48, 0x48), (0xB0, 0x3E, 0x40))
        case .rightOnly: return ((0x42, 0xA0, 0x3C), (0x38, 0x8C, 0x34))
        case .changed: return ((0x8A, 0x56, 0xE6), (0x7A, 0x4C, 0xD0))
        }
    }

    static func background(_ status: RowStatus, increaseContrast: Bool = DisplayOptions.increaseContrast) -> NSColor? {
        let pale: (light: RGB, dark: RGB)
        switch status {
        case .unchanged: return nil
        case .leftOnly: pale = ((0xFC, 0xEB, 0xEB), (0x4A, 0x24, 0x26))
        case .rightOnly: pale = ((0xE3, 0xFA, 0xDF), (0x1F, 0x40, 0x22))
        case .changed: pale = ((0xEE, 0xE8, 0xFC), (0x37, 0x2C, 0x55))
        }
        return color(pale, towards: strong(status), by: increaseContrast ? 0.3 : 0)
    }

    static func selected(_ status: RowStatus) -> NSColor {
        guard let strong = strong(status) else { return .selectedContentBackgroundColor }
        return color(strong, towards: nil, by: 0)
    }

    /// The pale arrow of a staged row in the gutter.
    static func accent(_ status: RowStatus, increaseContrast: Bool = DisplayOptions.increaseContrast) -> NSColor {
        let pale: (light: RGB, dark: RGB)
        switch status {
        case .unchanged: return increaseContrast ? .secondaryLabelColor : .tertiaryLabelColor
        case .leftOnly: pale = ((0xF4, 0xB8, 0xB8), (0x8A, 0x3A, 0x3C))
        case .rightOnly: pale = ((0x9C, 0xE6, 0x90), (0x3A, 0x7A, 0x34))
        case .changed: pale = ((0xCD, 0xB6, 0xF7), (0x5E, 0x46, 0x9A))
        }
        return color(pale, towards: strong(status), by: increaseContrast ? 0.6 : 0)
    }

    /// A light/dark colour, `fraction` of the way towards `target`.
    private static func color(_ base: (light: RGB, dark: RGB), towards target: (light: RGB, dark: RGB)?,
                              by fraction: Double) -> NSColor {
        func mix(_ a: RGB, _ b: RGB?) -> RGB {
            guard let b else { return a }
            func one(_ x: Int, _ y: Int) -> Int { x + Int((Double(y - x) * fraction).rounded()) }
            return (one(a.0, b.0), one(a.1, b.1), one(a.2, b.2))
        }
        let light = mix(base.light, target?.light), dark = mix(base.dark, target?.dark)
        return NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
    }
}
