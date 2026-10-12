// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// Walks the accessibility hierarchy of a window, the way VoiceOver sees
/// it (`accessibilityChildren()` from the content view down), and reports
/// the interactive elements a screen-reader user could not identify: no
/// label, no title, no placeholder and no title element.
///
/// It reads only the NSAccessibility protocol, so it works on windows that
/// were never put on screen (the unit tests build them offscreen).
@MainActor
enum AccessibilityAudit {
    /// One element of the walk.
    struct Element: @unchecked Sendable {
        let role: NSAccessibility.Role
        let name: String?
        let identifier: String?
        /// Where the element sits: the roles (and names) of its ancestors.
        let path: String
        let object: AnyObject

        /// Acted on, so it must be named. The arrows and page areas of a
        /// scroll bar are AppKit's own and named by their role description.
        var isInteractive: Bool {
            AccessibilityAudit.interactiveRoles.contains(role) && !path.hasSuffix(NSAccessibility.Role.scrollBar.rawValue)
        }
        var isLabeled: Bool { !(name ?? "").isEmpty }

        var description: String {
            "\(path) > \(role.rawValue)" + (identifier.map { " #\($0)" } ?? "")
        }
    }

    /// Roles a user acts on, which must therefore be named.
    nonisolated static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .textArea,
        .slider, .comboBox, .incrementor, .link, .disclosureTriangle, .colorWell,
        .tabGroup, .radioGroup, .table, .outline, .list,
    ]

    /// The name VoiceOver would read: label, title, placeholder, or the
    /// title of the element that names it.
    static func name(of element: AnyObject) -> String? {
        guard let element = element as? NSAccessibilityProtocol else { return nil }
        let object = element as AnyObject
        func text(_ value: Any?) -> String? {
            switch value {
            case let string as String: return string.isEmpty ? nil : string
            case let attributed as NSAttributedString: return attributed.string.isEmpty ? nil : attributed.string
            default: return nil
            }
        }
        if let label = text(element.accessibilityLabel()) { return label }
        if object.responds(to: #selector(NSAccessibilityProtocol.accessibilityTitle)),
           let title = text(object.accessibilityTitle?()) { return title }
        if object.responds(to: #selector(NSAccessibilityProtocol.accessibilityPlaceholderValue)),
           let placeholder = text(object.accessibilityPlaceholderValue?()) { return placeholder }
        if object.responds(to: #selector(NSAccessibilityProtocol.accessibilityTitleUIElement)),
           let titleElement = object.accessibilityTitleUIElement?() as AnyObject?,
           let title = name(of: titleElement) { return title }
        return nil
    }

    /// Every element under `root`, depth first, parents before children.
    static func walk(_ root: AnyObject, limit: Int = 20_000, tableRows: Int = 200) -> [Element] {
        var result: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject, path: String, depth: Int) {
            guard result.count < limit, depth < 64, seen.insert(ObjectIdentifier(object)).inserted,
                  let element = object as? NSAccessibilityProtocol else { return }
            var path = path
            if element.isAccessibilityElement(), let role = element.accessibilityRole() {
                let identifier = element.accessibilityIdentifier().flatMap { $0.isEmpty ? nil : $0 }
                result.append(Element(role: role, name: name(of: object), identifier: identifier,
                                      path: path, object: object))
                path += (path.isEmpty ? "" : " > ") + role.rawValue + (identifier.map { "#" + $0 } ?? "")
            }
            for child in element.accessibilityChildren() ?? [] {
                visit(child as AnyObject, path: path, depth: depth + 1)
            }
            // A view-based table makes its cells only for rows on screen;
            // ask for every row's cells (up to `tableRows`), as VoiceOver
            // would reach them by scrolling.
            if let table = object as? NSTableView {
                for row in 0 ..< min(table.numberOfRows, tableRows) {
                    for column in 0 ..< table.numberOfColumns {
                        if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) {
                            visit(cell, path: path + " > row \(row)", depth: depth + 1)
                        }
                    }
                }
            }
        }
        visit(root, path: "", depth: 0)
        return result
    }

    /// The interactive elements under `root` that have no name.
    static func unlabeled(in root: AnyObject) -> [Element] {
        walk(root).filter { $0.isInteractive && !$0.isLabeled }
    }

    /// The interactive elements of a window's content (and of its title
    /// bar accessories) that have no name.
    static func unlabeled(in window: NSWindow) -> [Element] {
        guard let content = window.contentView else { return [] }
        return unlabeled(in: content)
    }
}

extension NSControl {
    /// Names the control for VoiceOver. Inside a custom accessibility
    /// group, AppKit exposes a control through its cell, which does not see
    /// a label set on the control view, so the cell gets it too.
    func setAccessibleName(_ name: String?, help: String? = nil) {
        setAccessibilityLabel(name)
        cell?.setAccessibilityLabel(name)
        if let help {
            setAccessibilityHelp(help)
            cell?.setAccessibilityHelp(help)
        }
    }

    /// Hides a decorative control (an icon next to a label) from VoiceOver.
    func hideFromAccessibility() {
        setAccessibilityElement(false)
        cell?.setAccessibilityElement(false)
    }
}
