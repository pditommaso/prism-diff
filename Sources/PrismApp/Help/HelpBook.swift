// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismProtocol

/// Prism's built-in help: a handful of topics written for Prism, shown in
/// the Help window (Help > Prism Help). The shortcut list is read from the
/// app's own main menu, so it always matches what the menus do.
struct HelpTopic: Equatable, Sendable {
    /// Block of a topic's text.
    enum Block: Equatable, Sendable {
        case heading(String)
        case paragraph(String)
        /// Commands or configuration, shown in a monospaced font.
        case code(String)
        /// One item of a bulleted list.
        case bullet(String)
        /// A shortcut row: what it does, and the keys.
        case shortcut(String, String)
    }

    let id: String
    let title: String
    let blocks: [Block]

    /// Every word of the topic, for the search field.
    var searchableText: String {
        ([title] + blocks.map {
            switch $0 {
            case let .heading(text), let .paragraph(text), let .code(text), let .bullet(text): text
            case let .shortcut(action, keys): action + " " + keys
            }
        }).joined(separator: "\n")
    }

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
    }
}

@MainActor
enum HelpBook {
    static let gettingStartedID = "opening"
    static let shortcutsID = "shortcuts"

    /// The topics in reading order. The shortcuts come from `menu`, the
    /// app's main menu.
    static func topics(menu: NSMenu) -> [HelpTopic] {
        [
            welcome, opening, views, editing, merge, folders, tabs, commandLine, git, accessibility,
            shortcuts(from: menu),
        ]
    }

    static let welcome = HelpTopic(id: "welcome", title: "Welcome to Prism", blocks: [
        .paragraph("Prism compares text files and folders side by side, and helps you combine two or three versions of a file into one."),
        .heading("What you can do"),
        .bullet("Compare two text files and see every inserted, deleted and changed line, down to the words that differ."),
        .bullet("Copy changes from one side to the other, edit either side, and save."),
        .bullet("Resolve merge conflicts left by git, with the common ancestor taken into account."),
        .bullet("Compare two folders, open any pair of files inside them, and copy files across."),
        .bullet("Review everything git, Mercurial, Subversion or Perforce reports as changed, in one window."),
        .heading("About this project"),
        .paragraph(AboutContent.nonAffiliation),
        .paragraph("Prism is free software under the Apache License 2.0. Source code, releases and the issue tracker are at github.com/pditommaso/prism-diff."),
    ])

    static let opening = HelpTopic(id: gettingStartedID, title: "Opening a Comparison", blocks: [
        .paragraph("A new Prism window waits for the files to compare. Any of these starts a comparison:"),
        .bullet("Drop two files, or two folders, on the window. Drop one file and Prism waits for the second."),
        .bullet("Press Return or Space on the drop area (or click it) and choose two files or two folders. File > Open (Command-O) does the same."),
        .bullet("Copy some text and choose File > New from Clipboard (Shift-Command-N); copy other text and choose Edit > Paste to Comparison (Option-Command-V)."),
        .bullet("From Terminal, run prism with two paths (see The prism Command)."),
        .bullet("Drop files on the Prism icon in the Dock, or choose a recent pair from File > Open Recent."),
        .paragraph("A pair of files opens a text comparison; a pair of folders opens a folder comparison. Three or more files go on the file shelf, where you choose which two to compare."),
    ])

    static let views = HelpTopic(id: "views", title: "Reading a Text Comparison", blocks: [
        .paragraph("The left side is A and the right side is B. Lines only in B are inserted, lines only in A are deleted, and lines that differ are changed; inside a changed line the words that differ are highlighted more strongly."),
        .heading("Three layouts"),
        .bullet("Blocks (Command-1): A and B side by side, with padding so that matching lines stay level."),
        .bullet("Fluid (Command-2): A and B side by side without padding; lines between the panes join each difference to its partner."),
        .bullet("Unified (Command-3): one column, with A's lines just above B's at each difference."),
        .heading("Moving around"),
        .bullet("View > Next Change (Command-Down Arrow) and Previous Change (Command-Up Arrow) select each difference in turn; the bottom bar says which one you are on."),
        .bullet("Edit > Find (Command-F) searches A or B; Command-G and Shift-Command-G step through the matches."),
        .bullet("Ignore Whitespace (Shift-Command-') hides differences in spaces and tabs at the start and end of lines. Wrap Lines (Shift-Command-K) wraps long lines."),
        .bullet("Edit > Swap A & B (Command-\\) exchanges the two sides."),
        .bullet("The path bar above each side shows where the file lives; click a part of it to switch that side to a neighbouring file or folder."),
        .paragraph("Settings (Command-,) chooses a light or dark text background, one colour or a colour per kind of difference, and the font."),
    ])

    static let editing = HelpTopic(id: "editing", title: "Editing and Copying Changes", blocks: [
        .paragraph("Select a difference, then use the Merge menu:"),
        .bullet("Copy to Right (Command-Right Arrow) replaces B's lines with A's; Copy to Left (Command-Left Arrow) does the opposite."),
        .bullet("Keep Both (Option-Command-Right or Left Arrow) keeps the lines of both sides, in the order you choose."),
        .bullet("Reset Selection (Option-Command-Delete) puts the difference back as it was."),
        .paragraph("You can also type in either side. Every change can be undone (Command-Z). File > Save (Command-S) writes the edited side back in its original encoding and line endings; a window with unsaved changes asks before it closes."),
    ])

    static let merge = HelpTopic(id: "merge", title: "Resolving a Three-Way Merge", blocks: [
        .paragraph("When git stops a merge with conflicts, git mergetool can open each conflicted file in Prism (see Git Setup). The merge window shows A, the result and B; Unified shows A and B interleaved next to the result."),
        .paragraph("Changes made on only one side are taken automatically. Where both sides changed the same lines there is a conflict: it is shown in yellow, and the result holds an empty line until you decide."),
        .bullet("View > Next Conflict (Option-Command-Down Arrow) and Previous Conflict (Option-Command-Up Arrow) move between conflicts."),
        .bullet("Merge > Choose Left (Command-Right Arrow) or Choose Right (Command-Left Arrow) takes one side; Choose Both takes the two in the order you pick; Reset Selection undoes the choice."),
        .bullet("Double-click the result to type your own text for that part."),
        .paragraph("The header counts the conflicts still open. Save (Command-S) when it reads Resolved Document, then close the window: git learns that the file is resolved. Closing with conflicts left, or without saving, tells git the merge is not finished."),
    ])

    static let folders = HelpTopic(id: "folders", title: "Comparing Folders", blocks: [
        .paragraph("A folder comparison lists both folders side by side, with matching items on the same row. Changed items, items only in A and items only in B have their own colours; the checkboxes in the bottom bar show or hide each kind."),
        .bullet("Use the arrow keys to move through the list. Return (or a double-click) opens the selected row in a new tab: a pair of folders shows their contents, a pair of files their text comparison. Command-double-click opens it in a new window instead."),
        .bullet("The path bar shows where each side lives; click a part of it to compare a neighbouring folder instead."),
        .heading("Copying files"),
        .bullet("Select rows and choose Merge > Copy to Right or Copy to Left, or press the arrow button between the two lists to cycle a row through its copy directions."),
        .bullet("Merge > Start Copying Files (Command-Return) copies everything you marked. Replaced items go to the Trash, and a copy can be cancelled while it runs."),
        .paragraph("Folder settings choose whether hidden files are listed and whether files are compared by content or only by size and date."),
    ])

    static let tabs = HelpTopic(id: "tabs", title: "Tabs, Windows and the File Shelf", blocks: [
        .bullet("File > New Tab (Command-T) adds an empty comparison to the window; Shift-Command-] and Shift-Command-[ move between tabs."),
        .bullet("Drag a tab out of the strip to give it a window of its own, or use its Move Tab to New Window command."),
        .bullet("Command-W closes the comparison in front, Shift-Command-W the whole window."),
        .bullet("The number on a tab counts its files; click it, or press Command-/, to show the file shelf."),
        .bullet("On the shelf, Right and Left Arrow make the next or previous file B; with Option they change A instead."),
        .bullet("Quit and Keep Windows (Option-Command-Q) brings every tab back, with its layout, at the next launch."),
    ])

    static let commandLine = HelpTopic(id: "prism", title: "The prism Command", blocks: [
        .paragraph("Prism comes with one command-line tool, prism:"),
        .bullet("prism A B opens a comparison of A and B in the Prism app, and is what version-control tools call. It accepts the same options as ksdiff, so setups written for ksdiff work once the name is changed."),
        .bullet("prism diff, prism sniff and prism merge3 compare files in Terminal without the app. To open a file that is named diff, sniff or merge3, write it as ./diff."),
        .heading("Installing it"),
        .paragraph("Choose Prism > Integration and install the command-line tool. Prism links prism into a folder on your PATH, /usr/local/bin or ~/bin. If another prism command is already on your PATH, Prism offers to link its own as prism-diff instead."),
        .paragraph("To link it by hand instead:"),
        .code("ln -s /Applications/Prism.app/Contents/Helpers/prism /usr/local/bin/prism"),
        .heading("Examples"),
        .code("prism draft-1.txt draft-2.txt      # compare two files\nprism old-site/ new-site/          # compare two folders\nprism --wait a.txt b.txt           # return when the window closes\nprism diff a.txt b.txt             # unified diff in Terminal"),
    ])

    static let git = HelpTopic(id: "git", title: "Git Setup", blocks: [
        .paragraph("Prism > Integration sets up git for you: it makes Prism git's diff and merge tool (or an extra one you pick with -t prism), and Remove restores your configuration exactly as it was."),
        .paragraph("To configure git by hand, add this to your global configuration (prism must be on your PATH):"),
        .code("""
        git config --global difftool.prism.cmd 'prism --partial-changeset --relative-path "$MERGED" -- "$LOCAL" "$REMOTE"'
        git config --global mergetool.prism.cmd 'prism --merge --output "$MERGED" --base "$BASE" -- "$LOCAL" --snapshot "$REMOTE" --snapshot'
        git config --global mergetool.prism.trustExitCode true
        git config --global diff.tool prism
        git config --global merge.tool prism
        git config --global difftool.prompt false
        git config --global mergetool.prompt false
        """),
        .paragraph("Then git difftool shows every changed file in one window, with the list of files beside the comparison, and git mergetool opens each conflicted file in a merge window."),
    ])

    static let accessibility = HelpTopic(id: "accessibility", title: "Accessibility", blocks: [
        .bullet("VoiceOver reads every button, list and line: lines are read with their side and number, and merge lines say whether they are part of a conflict."),
        .bullet("Every command has a menu item, most with a shortcut, and Tab moves between the controls of a window (turn on Keyboard Navigation in System Settings > Keyboard to reach buttons too)."),
        .bullet("With Increase Contrast on (System Settings > Accessibility > Display), differences, conflicts, folder rows and search matches use stronger colours."),
        .bullet("With Reduce Motion on, windows open and close without animation. Prism never animates scrolling: moving to a change, match or conflict happens at once."),
        .bullet("View > Increase Text Size (Command-+) and Decrease Text Size (Command--) change the text size of comparisons."),
    ])

    // MARK: shortcuts

    /// "Keyboard Shortcuts": every main-menu item that has one, by menu.
    static func shortcuts(from menu: NSMenu) -> HelpTopic {
        var blocks: [HelpTopic.Block] = [
            .paragraph("Every shortcut of the menus, menu by menu. Some apply only to text, merge or folder comparisons."),
        ]
        for top in menu.items {
            guard let submenu = top.submenu else { continue }
            let rows = shortcutRows(submenu)
            guard !rows.isEmpty else { continue }
            blocks.append(.heading(submenu.title == PrismInfo.appName ? "Prism" : submenu.title))
            blocks += rows.map { .shortcut($0.title, $0.keys) }
        }
        return HelpTopic(id: shortcutsID, title: "Keyboard Shortcuts", blocks: blocks)
    }

    private static func shortcutRows(_ menu: NSMenu) -> [(title: String, keys: String)] {
        var rows: [(title: String, keys: String)] = []
        for item in menu.items {
            if let submenu = item.submenu {
                rows += shortcutRows(submenu)
            } else if !item.keyEquivalent.isEmpty, !rows.contains(where: { $0.title == item.title }) {
                rows.append((item.title, describe(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)))
            }
        }
        return rows
    }

    /// "⌥⌘→" for Option-Command-Right Arrow.
    static func describe(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) || key != key.lowercased() { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        if modifiers.contains(.function) { text += "fn " }
        let names: [String: String] = [
            MainMenuBuilder.upArrow: "\u{2191}", MainMenuBuilder.downArrow: "\u{2193}",
            MainMenuBuilder.leftArrow: "\u{2190}", MainMenuBuilder.rightArrow: "\u{2192}",
            MainMenuBuilder.backspace: "\u{232B}", "\r": "\u{21A9}", "\t": "\u{21E5}", " ": "Space",
        ]
        return text + (names[key] ?? key.uppercased())
    }

    // MARK: rendering

    /// The topic as styled text for the Help window.
    static func render(_ topic: HelpTopic) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func paragraphStyle(spacing: CGFloat = 8, indent: CGFloat = 0, tabs: [CGFloat] = []) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.headIndent = indent
            style.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
            return style
        }
        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: string + "\n", attributes: attributes))
        }
        append(topic.title, [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.labelColor,
                             .paragraphStyle: paragraphStyle(spacing: 12)])
        for block in topic.blocks {
            switch block {
            case let .heading(heading):
                append(heading, [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
                                 .paragraphStyle: paragraphStyle(spacing: 6)])
            case let .paragraph(paragraph):
                append(paragraph, [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle()])
            case let .bullet(item):
                append("\u{2022}\t" + item, [.font: body, .foregroundColor: NSColor.labelColor,
                                             .paragraphStyle: paragraphStyle(spacing: 4, indent: 16, tabs: [16])])
            case let .code(code):
                append(code, [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                              .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle(spacing: 10)])
            case let .shortcut(action, keys):
                append(action + "\t" + keys, [.font: body, .foregroundColor: NSColor.labelColor,
                                              .paragraphStyle: paragraphStyle(spacing: 2, tabs: [260])])
            }
        }
        return text
    }
}
