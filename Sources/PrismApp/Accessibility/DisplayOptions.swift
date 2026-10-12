// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// The system's display accommodations that change how Prism draws:
/// Increase Contrast (stronger difference bands, borders and highlights)
/// and Reduce Motion (no animated scrolling or transitions).
///
/// Prism animates nothing of its own: scrolling to a change, a match or a
/// conflict jumps at once, and panes, bars and the shelf appear without a
/// transition (a unit test keeps animation APIs out of the sources). Under
/// Reduce Motion, windows also open and close without their zoom.
///
/// Tests set the overrides instead of changing the system settings.
@MainActor
enum DisplayOptions {
    /// Replaces the system's Increase Contrast setting (tests).
    nonisolated(unsafe) static var increaseContrastOverride: Bool?
    /// Replaces the system's Reduce Motion setting (tests).
    nonisolated(unsafe) static var reduceMotionOverride: Bool?

    /// System Settings > Accessibility > Display > Increase contrast.
    nonisolated static var increaseContrast: Bool {
        increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// System Settings > Accessibility > Display > Reduce motion.
    nonisolated static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static var observer: NSObjectProtocol?

    /// Follows changes of the system settings: open comparisons pick up
    /// the matching theme (through `TextSettings.didChange`) and every
    /// window redraws, so folder rows and merge conflicts follow as well.
    static func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { displayOptionsChanged() }
        }
    }

    /// Applies the current settings to every open window.
    static func displayOptionsChanged() {
        NotificationCenter.default.post(name: TextSettings.didChange, object: nil)
        for window in NSApp?.windows ?? [] {
            applyMotion(to: window)
            window.contentView.map(redraw)
        }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews { redraw(subview) }
    }

    /// Window open and close animations follow Reduce Motion.
    static func applyMotion(to window: NSWindow) {
        window.animationBehavior = reduceMotion ? .none : .default
    }
}

// MARK: - contrast

extension ThemeColor {
    /// Relative luminance (WCAG 2), for contrast checks.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio between two opaque colours (1 to 21).
    static func contrast(_ x: ThemeColor, _ y: ThemeColor) -> Double {
        let (a, b) = (x.luminance, y.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour moved `fraction` of the way towards `other` (alpha too).
    func mixed(with other: ThemeColor, _ fraction: Double) -> ThemeColor {
        ThemeColor(red: red + (other.red - red) * fraction, green: green + (other.green - green) * fraction,
                   blue: blue + (other.blue - blue) * fraction, alpha: alpha + (other.alpha - alpha) * fraction)
    }
}

extension DifferenceColors {
    /// Stronger colours for Increase Contrast: bands, word highlights and
    /// line-number cells move towards the difference's border colour, and
    /// the border itself towards the text colour, so each kind stands out
    /// clearly from the background and from the others.
    func contrasted(text: ThemeColor) -> DifferenceColors {
        let edge = border.mixed(with: text, 0.35)
        return DifferenceColors(band: band.mixed(with: border, 0.35), border: edge,
                                word: word.mixed(with: border, 0.55), gutter: gutter.mixed(with: border, 0.5),
                                selectedBand: selectedBand.mixed(with: border, 0.45),
                                selectedWord: selectedWord.mixed(with: edge, 0.5),
                                selectedGutter: selectedGutter.mixed(with: text, 0.3), selectedNumber: selectedNumber)
    }
}

extension Theme {
    /// True for a theme made by `contrasted()`.
    var isContrasted: Bool { id.hasSuffix("-contrast") }

    /// The theme with Increase Contrast applied: stronger difference
    /// colours, unchanged text drawn like changed text, and darker (or,
    /// on dark backgrounds, lighter) line numbers and rules.
    func contrasted() -> Theme {
        var theme = self
        theme.id += "-contrast"
        theme.equalText = text
        theme.lineNumber = lineNumber.mixed(with: text, 0.5)
        theme.gutterBorder = gutterBorder.mixed(with: text, 0.4)
        theme.divider = divider.mixed(with: text, 0.4)
        theme.invisible = invisible.mixed(with: text, 0.3)
        theme.insert = insert.contrasted(text: text)
        theme.delete = delete.contrasted(text: text)
        theme.change = change.contrasted(text: text)
        return theme
    }
}
