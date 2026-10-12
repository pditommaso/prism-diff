// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import PrismIntegration
import PrismProtocol
import PrismTestSupport
import Testing
@testable import PrismApp

@Test func rowsGroupFilesByFolderWithRootFirst() {
    let rows = ChangesetRows(relativePaths: ["src/b.c", "README", "docs/x.md", "src/a.c", "Makefile"])
    #expect(rows.rows == [
        .group("Root Path"), .file(1), .file(4),
        .group("docs"), .file(2),
        .group("src"), .file(0), .file(3),
    ])
    #expect(rows.entryOrder == [1, 4, 2, 0, 3])
    #expect(rows.row(ofEntry: 3) == 7)
    #expect(ChangesetRows(relativePaths: []).rows.isEmpty)
}

@MainActor
@Test func changedFileCountText() {
    #expect(ChangesetSidebarView.countText(1) == "1 changed file")
    #expect(ChangesetSidebarView.countText(3) == "3 changed files")
}

private func entry(_ path: String, _ status: FileStatus = .changed, leftSnapshot: Bool = true,
                   left: String? = nil, right: String? = nil) -> ChangesetEntry {
    let a = left ?? "/tmp/snap/\(path)"
    let b = right ?? "/work/\(path)"
    return ChangesetEntry(relativePath: path, status: status, files: [
        ComparisonFile(originalPath: a, path: a, isSnapshot: leftSnapshot),
        ComparisonFile(originalPath: b, path: b, isSnapshot: false),
    ])
}

@MainActor
@Test func snapshotSidesShowOnlyTheirName() {
    #expect(ChangesetWindowController.display(of: entry("a.txt")) == (.nameOnly, .path))
    let added = entry("n.txt", .added, leftSnapshot: false, left: "/dev/null")
    #expect(ChangesetWindowController.display(of: added) == (.absent, .path))
    #expect(ChangesetWindowController.urls(of: added).a.path == "/dev/null")
}

@MainActor
@Test func snapshotFilesAreMarkedReadOnly() {
    #expect(ChangesetWindowController.snapshotSides(of: entry("a.txt")) == [.a])
    #expect(ChangesetWindowController.snapshotSides(of: entry("a.txt", leftSnapshot: false)).isEmpty)
    let files = [
        ComparisonFile(originalPath: "/x/a", path: "/x/a", isSnapshot: false),
        ComparisonFile(originalPath: "/x/b", path: "/s/b", isSnapshot: true),
    ]
    #expect(AppIPCService.snapshotSides(files, at: 0) == [.b])
    #expect(AppIPCService.snapshotSides(files, at: 2).isEmpty)
}

@MainActor
@Test func sidebarFollowsAppendsAndNavigation() throws {
    _ = NSApplication.shared
    let fixtureA = Corpus.fixture("text/a.swift").path
    let fixtureB = Corpus.fixture("text/b.swift").path
    let document = DocumentContent(
        id: "doc-9", kind: .partialChangeset, title: "Changes in repo", tool: .git,
        entries: [entry("one.swift", left: fixtureA, right: fixtureB)], isComplete: false)
    let controller = ChangesetWindowController(document: document)
    defer { controller.close() }
    #expect(controller.window?.title == "Changes in repo")
    #expect(controller.title == "Changes in repo")
    #expect(controller.sidebarView.countLabel.stringValue == "1 changed file")
    #expect(controller.sidebarView.selectedEntry == 0)
    #expect(controller.sidebar === controller.sidebarView)
    // The prism snapshot side refuses merges and typing.
    #expect(controller.session.snapshotSides == [.a])
    #expect(controller.session.refusal(toChange: .a) != nil)

    controller.append([entry("sub/two.swift", left: fixtureB, right: fixtureA), entry("three.swift", left: fixtureA, right: fixtureB)])
    #expect(controller.fileCount == 3)
    #expect(controller.sidebarView.countLabel.stringValue == "3 changed files")
    #expect(controller.sidebarView.selectedEntry == 0)    // the selection stays

    // Display order: Root Path (one, three), then sub (two).
    controller.selectNextFile(nil)
    #expect(controller.sidebarView.selectedEntry == 2)
    #expect(controller.urlA.path == fixtureA)
    controller.selectNextFile(nil)
    #expect(controller.sidebarView.selectedEntry == 1)
    #expect(controller.urlA.path == fixtureB)
    #expect(!controller.sidebarView.moveSelection(by: 1))
    controller.selectPreviousFile(nil)
    #expect(controller.sidebarView.selectedEntry == 2)
    controller.markComplete()
    #expect(controller.isComplete)
}

@Test func compareURLsAcceptOnlyTwoLocalRegularFiles() {
    let regular: (String) -> Bool = { $0.hasPrefix("/tmp/") }
    func parse(_ text: String) -> [String]? {
        AppDelegate.compareURLs(from: URL(string: text)!, isRegularFile: regular)?.map(\.path)
    }
    #expect(parse("prism://compare?url2=file:///tmp/b%20c.txt&url=file:///tmp/a.txt") == ["/tmp/a.txt", "/tmp/b c.txt"])
    #expect(parse("prism://compare?url=/tmp/x&url2=/tmp/y") == ["/tmp/x", "/tmp/y"])
    #expect(parse("prism://compare?url=file://localhost/tmp/x&url2=/tmp/y") == ["/tmp/x", "/tmp/y"])
    #expect(parse("prism://register?url=/tmp/x&url2=/tmp/y") == nil)
    #expect(parse("other://compare?url=/tmp/x&url2=/tmp/y") == nil)
    #expect(parse("prism://compare") == nil)
    #expect(parse("prism://compare?url=/tmp/x") == nil)                       // one file
    #expect(parse("prism://compare?url=/tmp/x&url2=/tmp/y&url3=/tmp/z") == nil) // extra item
    #expect(parse("prism://compare?url=relative&url2=/tmp/y") == nil)
    #expect(parse("prism://compare?url=/etc/hosts&url2=/tmp/y") == nil)         // not regular (by stub)
}

// Regression probe from the M5 check.
@Test func compareURLsRejectHostsAutomountsAndBulk() {
    var calls: [String] = []
    let lock = NSLock()
    let recording: (String) -> Bool = { path in lock.withLock { calls.append(path) }; return true }
    let many = (1...40).map { "url\($0)=/etc/hosts" }.joined(separator: "&")
    #expect(AppDelegate.compareURLs(from: URL(string: "prism://compare?\(many)")!, isRegularFile: recording) == nil)
    let odd = "url=file://attacker.example/etc/passwd&url2=/tmp/x"
    #expect(AppDelegate.compareURLs(from: URL(string: "prism://compare?\(odd)")!, isRegularFile: recording) == nil)
    let automount = "url=/net/attacker.example/share/x&url2=/tmp/x"
    #expect(AppDelegate.compareURLs(from: URL(string: "prism://compare?\(automount)")!, isRegularFile: recording) == nil)
    let network = "url=/tmp/x&url2=/Network/Servers/h/x"
    #expect(AppDelegate.compareURLs(from: URL(string: "prism://compare?\(network)")!, isRegularFile: recording) == nil)
    let sneaky = "url=/tmp/../net/h/x&url2=/tmp/x"
    #expect(AppDelegate.compareURLs(from: URL(string: "prism://compare?\(sneaky)")!, isRegularFile: recording) == nil)
    #expect(!calls.contains { $0.lowercased().hasPrefix("/net") || $0.lowercased().hasPrefix("/network") })
    #expect(AppDelegate.compareURLs(from: URL(string: "prism://compare?url=/dev/fd/0&url2=/etc/hosts")!) == nil)
}

@Test func launchedByCLISkipsTheAboutWindow() {
    #expect(AppDelegate.wantsAboutAtLaunch(arguments: ["Prism"], environment: [:]))
    #expect(!AppDelegate.wantsAboutAtLaunch(arguments: ["Prism"], environment: ["PRISM_LAUNCHED_BY_CLI": "123"]))
}

// MARK: Integration environment

@Test func integrationRootRedirectsEverything() {
    let env = IntegrationEnvironment.current(
        environment: ["PRISM_INTEGRATION_ROOT": "/tmp/root", "PATH": "/usr/bin", "GIT_CONFIG_GLOBAL": "/elsewhere"],
        bundle: URL(filePath: "/Applications/Prism.app"),
        home: URL(filePath: "/Users/me"))
    #expect(env.destinations.map(\.path) == ["/tmp/root/bin"])
    #expect(env.gitEnvironment["GIT_CONFIG_GLOBAL"] == "/tmp/root/gitconfig")
    #expect(env.gitStateFile.path == "/tmp/root/git-integration.json")
    #expect(env.helpersDirectory.path == "/Applications/Prism.app/Contents/Helpers")
    #expect(env.searchPath.isEmpty)
}

@Test func standardIntegrationEnvironment() {
    let env = IntegrationEnvironment.current(environment: ["PATH": "/usr/bin:/bin"],
                                             bundle: URL(filePath: "/Applications/Prism.app"),
                                             home: URL(filePath: "/Users/me"))
    #expect(env.destinations.map(\.path) == ["/usr/local/bin", "/Users/me/bin"])
    #expect(env.gitEnvironment["GIT_CONFIG_GLOBAL"] == nil)
    #expect(env.gitStateFile.path == "/Users/me/Library/Application Support/Prism/git-integration.json")
    #expect(env.searchPath.map(\.path) == ["/usr/bin", "/bin"])
}

@Test func toolCommandForGit() {
    let env = IntegrationEnvironment.current(environment: [:], bundle: URL(filePath: "/Applications/Prism.app"),
                                             home: URL(filePath: "/Users/me"))
    #expect(env.toolCommand(state: .installed(URL(filePath: "/usr/local/bin/prism"))) == "prism")
    #expect(env.toolCommand(state: .installed(URL(filePath: "/Users/me/bin/prism"))) == "/Users/me/bin/prism")
    #expect(env.toolCommand(state: .installed(URL(filePath: "/usr/local/bin/prism-diff"))) == "prism-diff")
    let foreign = CommandLineToolInstaller.ForeignTool(path: URL(filePath: "/usr/local/bin/prism"),
                                                       resolvedPath: URL(filePath: "/x"), ownerName: nil, signingIdentifier: nil)
    #expect(env.toolCommand(state: .foreign(foreign)) == "/Applications/Prism.app/Contents/Helpers/prism")
    #expect(env.toolCommand(state: .notInstalled) == "/Applications/Prism.app/Contents/Helpers/prism")
}

@Test func testOverridesNeedATestingFlagInRelease() {
    #if DEBUG
    #expect(IntegrationEnvironment.allowsTestOverrides([:]))
    #else
    #expect(!IntegrationEnvironment.allowsTestOverrides([:]))
    #expect(IntegrationEnvironment.allowsTestOverrides(["PRISM_TESTING": "1"]))
    #endif
}

/// Moving through the sidebar with the arrow keys must keep the keyboard on
/// the sidebar: loading the newly selected file may not take the focus.
@MainActor
@Test func sidebarKeepsTheKeyboardWhileFilesLoad() async throws {
    _ = NSApplication.shared
    let fixtureA = Corpus.fixture("text/a.swift").path
    let fixtureB = Corpus.fixture("text/b.swift").path
    let document = DocumentContent(
        id: "doc-focus", kind: .partialChangeset, title: "Changes in repo", tool: .git,
        entries: [entry("one.swift", left: fixtureA, right: fixtureB),
                  entry("two.swift", left: fixtureB, right: fixtureA),
                  entry("three.swift", left: fixtureA, right: fixtureB)], isComplete: true)
    let controller = ChangesetWindowController(document: document)
    defer { controller.close() }
    let window = try #require(controller.window)
    let table = controller.sidebarView.tableView
    for _ in 0..<3 {
        #expect(window.makeFirstResponder(table))
        _ = controller.sidebarView.moveSelection(by: 1)
        let deadline = ContinuousClock.now + .seconds(90)
        while controller.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.firstResponder === table, "the sidebar lost the keyboard after a file loaded")
    }
}

/// `prism dirA dirB` sends a plain diff of two folders: it must open a folder
/// comparison, not a text one (which refuses folders).
@MainActor
@Test func cliFolderPairOpensAFolderComparison() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appending(path: "prism-cli-folders-\(UUID().uuidString)")
    let left = root.appending(path: "left"), right = root.appending(path: "right")
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var textOpened = 0
    var foldersOpened: [(URL, URL)] = []
    var hosts: [DocumentWindowController] = []
    let service = AppIPCService(
        socketPath: root.appending(path: "s.sock").path, securesDirectory: false,
        openComparison: { a, b in textOpened += 1; return ComparisonWindowController(a: a, b: b) },
        openFolders: { a, b in
            foldersOpened.append((a, b))
            let host = DocumentWindowController()
            hosts.append(host)
            return host
        },
        host: { _ in })
    let files = [left, right].map { ComparisonFile(originalPath: $0.path, path: $0.path, isSnapshot: false) }
    service.open(DocumentContent(id: "doc-folders", kind: .diff, title: "left | right", tool: .unknown,
                                 entries: [ChangesetEntry(relativePath: "", status: .changed, files: files)],
                                 isComplete: true))
    #expect(textOpened == 0)
    #expect(foldersOpened.count == 1)
    #expect(foldersOpened.first?.0.path == left.path && foldersOpened.first?.1.path == right.path)
    hosts.forEach { $0.close() }
}
