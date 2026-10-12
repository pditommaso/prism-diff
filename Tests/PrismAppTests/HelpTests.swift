// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Foundation
import PrismIntegration
import Testing
@testable import PrismApp

// M11 in-app Help: the topics, the shortcut list read from the main menu,
// the Help window and the non-affiliation notice. No window is shown.

@MainActor
private func topics() -> [HelpTopic] { HelpBook.topics(menu: MainMenuBuilder.make(target: NSObject())) }

private let repositoryRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@MainActor
@Test func helpCoversEverySubject() {
    let all = topics()
    #expect(Set(all.map(\.id)).count == all.count)
    for id in ["welcome", HelpBook.gettingStartedID, "views", "editing", "merge", "folders", "tabs", "prism", "git",
               "accessibility", HelpBook.shortcutsID] {
        #expect(all.contains { $0.id == id }, "no topic \(id)")
    }
    func text(_ id: String) -> String { all.first { $0.id == id }?.searchableText ?? "" }
    // Opening comparisons, the views, merge, folders, prism and git.
    #expect(text(HelpBook.gettingStartedID).contains("Drop two files"))
    for layout in ["Blocks", "Fluid", "Unified"] { #expect(text("views").contains(layout)) }
    #expect(text("merge").contains("git mergetool") && text("merge").contains("conflict"))
    #expect(text("folders").contains("Start Copying Files"))
    #expect(text("prism").contains("Prism > Integration") && text("prism").contains("Contents/Helpers/prism"))
    #expect(text("git").contains("difftool.prism.cmd") && text("git").contains("mergetool.prism.trustExitCode"))
    #expect(text("accessibility").contains("Increase Contrast") && text("accessibility").contains("Reduce Motion"))
    for topic in all {
        #expect(HelpBook.render(topic).length > topic.title.count + 40, "\(topic.id) is empty")
    }
}

/// The git commands in Help are the ones the Integration window writes.
@MainActor
@Test func helpGitCommandsMatchTheInstaller() {
    let git = topics().first { $0.id == "git" }?.searchableText ?? ""
    #expect(git.contains(GitConfigInstaller.difftoolCommand(tool: "prism")))
    #expect(git.contains(GitConfigInstaller.mergetoolCommand(tool: "prism")))
}

@MainActor
@Test func shortcutListComesFromTheMenus() {
    let shortcuts = HelpBook.shortcuts(from: MainMenuBuilder.make(target: NSObject()))
    var rows: [String: String] = [:]
    var headings: [String] = []
    for block in shortcuts.blocks {
        if case let .shortcut(title, keys) = block { rows[title] = keys }
        if case let .heading(title) = block { headings.append(title) }
    }
    #expect(headings.starts(with: ["Prism", "File", "Edit", "View", "Merge", "Window", "Help"]))
    #expect(rows["Next Change"] == "\u{2318}\u{2193}")
    #expect(rows["Next Conflict"] == "\u{2325}\u{2318}\u{2193}")
    #expect(rows["Copy to Right"] == "\u{2318}\u{2192}")
    #expect(rows["Reset Selection"] == "\u{2325}\u{2318}\u{232B}")
    #expect(rows["Find\u{2026}"] == "\u{2318}F")
    #expect(rows["Find Previous"] == "\u{21E7}\u{2318}G")
    #expect(rows["Start Copying Files"] == "\u{2318}\u{21A9}")
    #expect(rows["Select Next Tab"] == "\u{21E7}\u{2318}]")
    #expect(rows["Prism Help"] == "\u{2318}?")
    #expect(rows["Select Next B"] == "\u{2192}")
}

@MainActor
@Test func helpWindowSearchesAndSelectsTopics() throws {
    _ = NSApplication.shared
    let controller = HelpWindowController(topics: topics())
    defer { controller.close() }
    #expect(controller.window?.title == "Prism Help")
    #expect(controller.selectedTopic?.id == "welcome")
    #expect(controller.textView.string.contains(AboutContent.nonAffiliation))
    #expect(!controller.textView.isEditable && controller.textView.isSelectable)

    controller.select(topicID: "git")
    #expect(controller.selectedTopic?.id == "git")
    #expect(controller.textView.string.contains("git config --global"))
    #expect(controller.textView.accessibilityLabel() == "Help: Git Setup")

    controller.filter("mergetool")
    #expect(controller.shown.allSatisfy { $0.searchableText.localizedCaseInsensitiveContains("mergetool") })
    #expect(controller.shown.contains { $0.id == "merge" })
    #expect(controller.selectedTopic?.id == "git")      // still matching, still selected
    controller.filter("no such words anywhere")
    #expect(controller.shown.isEmpty && controller.selectedTopic == nil)
    #expect(controller.textView.string.contains("No help topic"))
    controller.filter("")
    #expect(controller.shown.count == controller.topics.count)

    // Getting Started opens on the topic about opening comparisons.
    controller.select(topicID: HelpBook.gettingStartedID)
    #expect(controller.selectedTopic?.title == "Opening a Comparison")
    #expect(controller.window?.autorecalculatesKeyViewLoop == true)
    #expect(controller.window?.initialFirstResponder === controller.topicList)
}

@MainActor
@Test func helpMenuOpensTheHelpWindow() throws {
    let menu = MainMenuBuilder.make(target: NSObject())
    let help = try #require(menu.item(withTitle: MainMenuBuilder.helpMenuTitle)?.submenu)
    #expect(help.item(withTitle: "Prism Help")?.action == #selector(AppDelegate.openHelp(_:)))
    #expect(help.item(withTitle: "Getting Started")?.action == #selector(AppDelegate.showGettingStarted(_:)))
}

/// The same notice, word for word, in About, Help and the README.
@MainActor
@Test func nonAffiliationNoticeIsTheSameEverywhere() throws {
    let notice = "Prism is an independent open-source project, not affiliated with Kaleidoscope. "
        + "The prism command accepts the same options as ksdiff for compatibility."
    #expect(AboutContent.nonAffiliation == notice)
    #expect(AboutContent.current.disclaimer == notice)
    #expect(HelpBook.welcome.searchableText.contains(notice))
    let readme = try String(contentsOf: repositoryRoot.appending(path: "README.md"), encoding: .utf8)
    #expect(readme.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: " ").contains(notice))
}
