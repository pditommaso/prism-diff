// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismProtocol

/// Where the app keeps its preferences: the user's defaults, or under
/// PRISM_TESTING=1 a separate suite, so that acceptance runs (which change
/// layouts, fonts and recent files through the menus) never rewrite the
/// owner's own settings, and a setting the owner chose never steers a test.
/// Launch arguments (`-prism.text.viewMode blocks`) override both.
enum AppDefaults {
    static let testingSuite = "io.github.pditommaso.prism.testing"

    /// The suite applies only to the app itself (`isApp`): unit tests keep
    /// their own process's defaults, apart from any app run.
    nonisolated static func store(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  isApp: Bool = Bundle.main.bundleIdentifier == PrismInfo.bundleIdentifier) -> UserDefaults {
        guard isApp, environment["PRISM_TESTING"] == "1", let suite = UserDefaults(suiteName: testingSuite) else {
            return .standard
        }
        return suite
    }

    nonisolated(unsafe) static let shared: UserDefaults = store()
}

/// Text-pane preferences, stored in the user defaults. Every setter posts
/// `TextSettings.didChange` so open comparisons can follow.
@MainActor
struct TextSettings {
    static let didChange = Notification.Name("io.github.pditommaso.prism.textSettingsDidChange")

    enum Key {
        static let dark = "prism.text.dark"
        static let singleColor = "prism.text.singleColor"
        static let fontName = "prism.text.fontName"
        static let fontSize = "prism.text.fontSize"
        static let ignoreWhitespace = "prism.text.ignoreWhitespace"
        static let wrapLines = "prism.text.wrapLines"
        static let viewMode = "prism.text.viewMode"
    }

    static let defaultFontSize: CGFloat = 11
    static let minimumFontSize: CGFloat = 6
    static let maximumFontSize: CGFloat = 72

    var defaults: UserDefaults = AppDefaults.shared

    /// Dark text background.
    var dark: Bool {
        get { defaults.bool(forKey: Key.dark) }
        nonmutating set { defaults.set(newValue, forKey: Key.dark); notify() }
    }

    /// One colour family for every kind of difference.
    var singleColor: Bool {
        get { defaults.bool(forKey: Key.singleColor) }
        nonmutating set { defaults.set(newValue, forKey: Key.singleColor); notify() }
    }

    /// New comparisons ignore whitespace at the line edges.
    var ignoreWhitespace: Bool {
        get { defaults.bool(forKey: Key.ignoreWhitespace) }
        nonmutating set { defaults.set(newValue, forKey: Key.ignoreWhitespace); notify() }
    }

    /// New comparisons wrap long lines.
    var wrapLines: Bool {
        get { defaults.bool(forKey: Key.wrapLines) }
        nonmutating set { defaults.set(newValue, forKey: Key.wrapLines); notify() }
    }

    /// The layout new comparisons open in: the last one used, Blocks until
    /// a layout was chosen. Not a preference other windows follow, so
    /// setting it posts nothing.
    var viewMode: ViewMode {
        get { defaults.string(forKey: Key.viewMode).flatMap(ViewMode.init(rawValue:)) ?? .blocks }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    /// The text font: the chosen face, or the system monospaced font at
    /// 11 pt when none was chosen.
    var font: NSFont {
        get {
            let stored = defaults.double(forKey: Key.fontSize)
            let size = stored > 0 ? min(max(CGFloat(stored), Self.minimumFontSize), Self.maximumFontSize)
                                  : Self.defaultFontSize
            if let name = defaults.string(forKey: Key.fontName), !name.isEmpty,
               let font = NSFont(name: name, size: size) {
                return font
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        nonmutating set {
            let system = NSFont.monospacedSystemFont(ofSize: newValue.pointSize, weight: .regular)
            if newValue.fontName == system.fontName {
                defaults.removeObject(forKey: Key.fontName)
            } else {
                defaults.set(newValue.fontName, forKey: Key.fontName)
            }
            defaults.set(Double(newValue.pointSize), forKey: Key.fontSize)
            notify()
        }
    }

    /// The chosen theme, strengthened when the system asks for more
    /// contrast (Accessibility > Display > Increase contrast).
    var theme: Theme {
        let theme = ThemeChoice.theme(dark: dark, singleColor: singleColor)
        return DisplayOptions.increaseContrast ? theme.contrasted() : theme
    }

    /// "Name – 11 pt", as shown in the preferences.
    static func describe(_ font: NSFont) -> String {
        let size = font.pointSize.rounded() == font.pointSize ? String(Int(font.pointSize))
                                                               : String(format: "%.1f", font.pointSize)
        let system = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        let name = font.fontName == system.fontName ? "System Monospaced" : (font.displayName ?? font.fontName)
        return "\(name) \u{2013} \(size) pt"
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
