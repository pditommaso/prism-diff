// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import os
import PrismProtocol

/// Application delegate: installs the main menu, opens comparisons and owns
/// the About and Settings windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch argument that keeps the About window closed at launch.
    nonisolated static let noAboutArgument = "--no-about"
    /// Environment variable that, when set to "0", does the same.
    nonisolated static let showAboutEnvironment = "PRISM_SHOW_ABOUT"

    private lazy var aboutController = AboutWindowController()
    private lazy var settingsController = SettingsWindowController()
    /// Open document windows (each with one or more comparison tabs).
    private(set) var documentWindows: [DocumentWindowController] = []
    /// Quitting saves the windows for the next launch (Quit and Keep
    /// Windows).
    private var keepWindowsAtQuit = false
    /// The Quit and Keep Windows choice of a review of unsaved changes.
    private var reviewKeepsWindows = false
    /// Files received from Finder or `open` that are waiting for a partner.
    private var pendingURLs: [URL] = []
    private var pendingFlush: Task<Void, Never>?
    private let launch = LaunchRequest.parse(CommandLine.arguments)
    /// The `prism` socket server and the windows it opens.
    private(set) var ipc: AppIPCService?
    private lazy var integrationController = IntegrationWindowController()
    /// Help > Prism Help; its shortcut list is read from the main menu.
    private lazy var helpController = HelpWindowController(topics: HelpBook.topics(menu: NSApp.mainMenu ?? NSMenu()))

    /// True unless the launch arguments or environment ask for no window
    /// at a plain launch (`--no-about`, `PRISM_SHOW_ABOUT=0`, or a start by
    /// prism). A plain launch shows the launch window (an empty document
    /// window to drop files on).
    nonisolated static func wantsAboutAtLaunch(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !arguments.dropFirst().contains(noAboutArgument)
            && environment[showAboutEnvironment] != "0"
            // Started by prism: the comparison it sends is the only window.
            && environment[IPCEnvironment.launchedByCLIVariable] == nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prism draws its own tabs: no system tab bar items in View.
        NSWindow.allowsAutomaticWindowTabbing = false
        DocumentWindowController.register = { [weak self] controller in self?.track(controller) }
        let menu = MainMenuBuilder.make(target: self)
        NSApp.mainMenu = menu
        if let windowMenu = menu.item(withTitle: MainMenuBuilder.windowMenuTitle)?.submenu {
            NSApp.windowsMenu = windowMenu
        }
        if let help = menu.item(withTitle: MainMenuBuilder.helpMenuTitle)?.submenu {
            NSApp.helpMenu = help
        }
        if let services = menu.items.first?.submenu?
            .item(withTitle: MainMenuBuilder.servicesMenuTitle)?.submenu {
            NSApp.servicesMenu = services
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DisplayOptions.startObserving()
        startIPC()
        let paths = launch.paths
        if paths.count >= 2 {
            open(urls: paths.map { URL(filePath: $0) }, initialChange: launch.initialChange)
        } else if !paths.isEmpty {
            receive(paths.map { URL(filePath: $0) })
        }
        let byClient = ProcessInfo.processInfo.environment[IPCEnvironment.launchedByCLIVariable] != nil
        if paths.isEmpty, !byClient {
            restoreWindows()
        }
        openDebugTabs()
        AppFocus.activate()
        // Files opened through Launch Services arrive in
        // application(_:open:), around this point. The launch window shows
        // only for a plain launch, once it is clear that no comparison is
        // coming.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.documentWindows.isEmpty, self.pendingURLs.isEmpty,
                  Self.wantsAboutAtLaunch() else { return }
            self.newWindow(nil)
        }
    }

    // MARK: prism

    private func startIPC() {
        let overridden = ProcessInfo.processInfo.environment[IPCEnvironment.socketPathVariable]?.isEmpty == false
        let service = AppIPCService(socketPath: IPCEnvironment.socketPath(), securesDirectory: !overridden,
                                    openComparison: { [unowned self] a, b in self.openTextComparison(a, b) },
                                    openFolders: { [unowned self] a, b in self.openFolderComparison(a, b) },
                                    host: { [unowned self] controller in self.host(controller) })
        do {
            try service.start()
            ipc = service
        } catch {
            // Another instance owns the socket; this one opens files only
            // through Finder and File > Open.
            PrismLog.ipc.error("prism integration disabled: \(String(describing: error), privacy: .public)")
            PerfLog.record("ipcFailed", ["message": "\(error)"])
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The windows first (plain file writes that nothing can hold up),
        // then the merges: a merge saved resolved must reach its prism
        // (exit 0) before the server stops.
        saveWindowsForQuit(keep: keepWindowsAtQuit || Self.quitKeepsWindowsByDefault)
        ipc?.finishMerges()
        ipc?.stop()
    }

    /// Writes the state of the document windows (front to back) for the
    /// next launch when `keep`, otherwise removes any saved state.
    private func saveWindowsForQuit(keep: Bool) {
        Self.saveWindows(frontToBack(documentWindows), keep: keep)
    }

    /// Saves `windows` to `url` (the state file) when `keep`, else removes
    /// it; clipboard snippets of windows that do not come back go. Returns
    /// what was saved.
    @discardableResult
    static func saveWindows(_ windows: [DocumentWindowController], keep: Bool,
                            to url: URL? = StateRestoration.fileURL) -> [WindowState] {
        guard keep else {
            StateRestoration.discard(url)
            ClipboardSnippets.cleanUp(keeping: [])
            return []
        }
        let kept = StateRestoration.save(windows, to: url)
        // Snippets of the windows that come back stay; the rest go.
        ClipboardSnippets.cleanUp(keeping: StateRestoration.files(of: kept))
        return kept
    }

    /// The system setting "Close windows when quitting an application"
    /// turned off keeps windows on every quit (never under tests, which
    /// must not leave windows for the next run).
    nonisolated static var quitKeepsWindowsByDefault: Bool {
        ProcessInfo.processInfo.environment[IPCEnvironment.testingVariable] != "1"
            && UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows")
    }

    /// Prism > Quit and Keep Windows (Option-Command-Q): the windows and
    /// their tabs come back at the next launch.
    @objc func quitKeepingWindows(_ sender: Any?) {
        keepWindowsAtQuit = true
        // Saved now as well as at termination, so the windows come back even
        // if termination ends early; a cancelled quit removes the file.
        StateRestoration.save(frontToBack(documentWindows))
        PerfLog.record("quitKeepingWindows", ["windows": documentWindows.count])
        NSApp.terminate(sender)
    }

    /// Test hook (PRISM_TESTING=1 only): `PRISM_DEBUG_OPEN_TABS="a|b;c|d"`
    /// opens one window with a tab per pair, so that acceptance runs get
    /// several tabs without typing or dropping files.
    private func openDebugTabs() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[IPCEnvironment.testingVariable] == "1",
              let spec = environment["PRISM_DEBUG_OPEN_TABS"], !spec.isEmpty else { return }
        let tabs = spec.split(separator: ";").flatMap { pair -> [WorkspaceTab] in
            DocumentWindowController.makeTabs(for: pair.split(separator: "|").map { URL(filePath: String($0)) })
        }
        guard !tabs.isEmpty else { return }
        let controller = DocumentWindowController()
        track(controller)
        for (index, tab) in tabs.enumerated() { controller.insert(tab, at: index) }
        controller.present(cascadingFrom: documentWindows.dropLast().last?.window)
    }

    /// Brings back the windows saved by the last Quit and Keep Windows.
    private func restoreWindows() {
        let states = StateRestoration.take()
        for state in states.reversed() {
            guard let controller = StateRestoration.makeWindow(state) else { continue }
            track(controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.selectTab(controller.selectedIndex)
        }
        if !states.isEmpty {
            PerfLog.record("stateRestored", ["windows": documentWindows.count,
                                             "tabs": documentWindows.map { $0.tabs.map(\.title) }])
        }
    }

    private func frontToBack(_ controllers: [DocumentWindowController]) -> [DocumentWindowController] {
        let order = NSApp.orderedWindows
        return controllers.sorted { a, b in
            (order.firstIndex { $0 === a.window } ?? .max) < (order.firstIndex { $0 === b.window } ?? .max)
        }
    }

    /// Shows the Integration window (command-line tools and git).
    @objc func showIntegration(_ sender: Any?) {
        integrationController.present()
    }

    /// `prism://compare?url=<file URL or path>&url2=<file URL or path>`:
    /// exactly the items `url` and `url2` (any other `url…` item rejects the
    /// link), each a local file URL or an absolute path to a regular file.
    /// URLs naming another host, and paths under `/net` or `/Network`
    /// (which would wake the automounter), are refused before the file
    /// system is touched. Returns nil for a link that is not acceptable.
    nonisolated static func compareURLs(
        from url: URL,
        isRegularFile: (String) -> Bool = { path in
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        }
    ) -> [URL]? {
        guard url.scheme?.lowercased() == PrismInfo.urlScheme, url.host?.lowercased() == "compare",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let urlItems = items.filter { $0.name.lowercased().hasPrefix("url") }
        guard urlItems.count == 2, Set(urlItems.map(\.name)) == ["url", "url2"] else { return nil }
        var files: [URL] = []
        for name in ["url", "url2"] {
            guard let value = urlItems.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
            let file: URL
            if let parsed = URL(string: value), parsed.scheme != nil {
                guard parsed.isFileURL else { return nil }
                if let host = parsed.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
                file = parsed
            } else if value.hasPrefix("/") {
                file = URL(filePath: value)
            } else {
                return nil
            }
            let path = (file.path as NSString).standardizingPath
            let lowered = path.lowercased()
            if lowered == "/net" || lowered.hasPrefix("/net/") || lowered == "/network" || lowered.hasPrefix("/network/") {
                return nil
            }
            guard isRegularFile(path) else { return nil }
            files.append(URL(filePath: path))
        }
        return files
    }

    private func openCompareURL(_ url: URL) {
        guard let files = Self.compareURLs(from: url) else {
            let alert = NSAlert()
            alert.messageText = "This link cannot be opened."
            alert.informativeText = "A Prism link must name two files on this Mac."
            alert.runModal()
            return
        }
        // Links can come from anywhere: ask before reading the files.
        let confirm = NSAlert()
        confirm.messageText = "Compare these files?"
        confirm.informativeText = "A link asks Prism to compare:\n\(files[0].path)\n\(files[1].path)"
        confirm.addButton(withTitle: "Compare")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        open(urls: files, initialChange: nil)
    }

    // MARK: opening files

    /// Finder, the Dock and `open -a Prism a b` deliver files here, possibly
    /// over several calls. They are collected briefly, then paired.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.filter { $0.scheme?.lowercased() == PrismInfo.urlScheme }.forEach(openCompareURL)
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { receive(files) }
    }

    private func receive(_ urls: [URL]) {
        pendingURLs += urls
        pendingFlush?.cancel()
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let urls = self.pendingURLs
            self.pendingURLs = []
            if urls.count == 1 {
                self.chooseSecondFile(for: urls[0])
            } else {
                self.open(urls: urls, initialChange: nil)
            }
        }
    }

    /// Opens what `urls` compare: more than two files make one comparison
    /// with them all on its file shelf; folders open in pairs; a last odd
    /// item waits for its partner in a launch window.
    private func open(urls: [URL], initialChange: Int?) {
        if urls.count > 2, !urls.contains(where: Self.isDirectory) {
            let controller = openTextComparison(urls[0], urls[1], initialChange: initialChange)
            controller.setShelfFiles(urls.map { ShelfEntry(url: $0) }, a: 0, b: 1)
            return
        }
        var index = 0
        while index + 1 < urls.count {
            openComparison(urls[index], urls[index + 1], initialChange: initialChange)
            index += 2
        }
        if index < urls.count {
            chooseSecondFile(for: urls[index])
        }
    }

    /// Two folders open a folder comparison; anything else a text one.
    func openComparison(_ a: URL, _ b: URL, initialChange: Int? = nil) {
        if Self.isDirectory(a) && Self.isDirectory(b) {
            openFolderComparison(a, b)
        } else {
            openTextComparison(a, b, initialChange: initialChange)
        }
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Starts tracking a document window (and forgets it once closed).
    func track(_ controller: DocumentWindowController) {
        guard !documentWindows.contains(where: { $0 === controller }) else { return }
        let previous = controller.onClose
        controller.onClose = { [weak self] closed in
            previous?(closed)
            self?.documentWindows.removeAll { $0 === closed }
        }
        controller.onOpenInNewWindow = { [weak self] a, b in self?.openComparison(a, b) }
        documentWindows.append(controller)
    }

    /// Shows a new document window holding `tab`.
    @discardableResult
    func openWindow(with tab: WorkspaceTab) -> DocumentWindowController {
        let previous = documentWindows.last?.window
        let controller = DocumentWindowController()
        track(controller)
        controller.insert(tab, at: 0)
        controller.present(cascadingFrom: previous)
        return controller
    }

    @discardableResult
    func openFolderComparison(_ a: URL, _ b: URL) -> FolderWindowController {
        RecentComparisons.shared.note([a, b])
        let document = FolderDocument(left: a, right: b)
        return openWindow(with: document.makeTab(relativePath: ""))
    }

    /// Opens a text comparison in a new window and returns its controller
    /// (the window is its host).
    @discardableResult
    func openTextComparison(_ a: URL, _ b: URL, initialChange: Int? = nil) -> ComparisonWindowController {
        RecentComparisons.shared.note([a, b])
        let tab = TextTab(a: a, b: b, key: "text:\(UUID().uuidString)", title: nil, initialChange: initialChange)
        openWindow(with: tab)
        return tab.controller
    }

    /// Shows a changeset (or any comparison built elsewhere) in a new
    /// window.
    func host(_ controller: ComparisonWindowController) {
        openWindow(with: TextTab(controller: controller, key: "text:\(UUID().uuidString)"))
    }

    /// File > New Window: a launch window to drop files on.
    @objc func newWindow(_ sender: Any?) {
        openWindow(with: LaunchTab())
    }

    /// File > New Tab with no document window in front: a new window.
    @objc func newTab(_ sender: Any?) { newWindow(sender) }

    /// File > New from Clipboard: a new window whose first file is the
    /// clipboard's text, waiting for a second.
    @objc func newFromClipboard(_ sender: Any?) {
        guard let url = ClipboardSnippets.writeClipboard() else { return NSSound.beep() }
        let launch = LaunchTab()
        openWindow(with: launch)
        launch.receive([url])
    }

    /// File > Close Comparison with a window that is not a document in
    /// front (About, Settings): closes it.
    @objc func closeComparison(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    /// File > Open Recent > a | b.
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String], paths.count == 2 else { return }
        let urls = paths.map { URL(filePath: $0) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) else {
            let alert = NSAlert()
            alert.messageText = "This comparison cannot be opened."
            alert.informativeText = "One of its files or folders no longer exists."
            alert.runModal()
            return
        }
        openComparison(urls[0], urls[1])
    }

    @objc func clearRecentComparisons(_ sender: Any?) {
        RecentComparisons.shared.clear()
    }

    /// Edit > Spelling > Show Spelling and Grammar.
    @objc func showGuessPanel(_ sender: Any?) {
        NSSpellChecker.shared.spellingPanel.orderFront(sender)
    }

    /// The document window in front (key, or frontmost).
    var frontDocumentWindow: DocumentWindowController? {
        if let key = NSApp.keyWindow?.windowController as? DocumentWindowController { return key }
        return PrismApplication.frontmostDocumentWindow(in: NSApp.orderedWindows)?.windowController
            as? DocumentWindowController
    }

    /// File > Open: pick files or folders; an empty tab in front gets
    /// them, otherwise they open in a new window.
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose two files or two folders to compare."
        panel.prompt = "Compare"
        guard panel.runModal() == .OK else { return }
        if let launch = frontDocumentWindow?.selectedTab as? LaunchTab {
            launch.receive(panel.urls)
        } else {
            open(urls: panel.urls, initialChange: nil)
        }
    }

    /// One file: a launch window shows it and waits for the second.
    private func chooseSecondFile(for first: URL) {
        let launch = LaunchTab()
        openWindow(with: launch)
        launch.receive([first])
    }

    /// Shows the Settings window.
    @objc func showSettings(_ sender: Any?) {
        settingsController.present()
    }

    /// Every text comparison: the text tabs of every document window.
    var textComparisons: [ComparisonWindowController] {
        documentWindows.flatMap { $0.textTabs.map(\.controller) }
    }

    /// Comparisons with unsaved changes, text still in an editor included
    /// (it is committed first). Those whose user already chose to discard
    /// their changes are left out.
    func unsavedComparisons() -> [ComparisonWindowController] {
        textComparisons.filter { $0.hasUnsavedChanges && !$0.closingConfirmed }
    }

    /// Quitting asks first about unresolved merges, then unsaved edits,
    /// then folder copies still running; no question is skipped.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var reply = NSApplication.TerminateReply.terminateCancel
        if confirmEndingMergesBeforeQuitting() {
            reply = confirmUnsavedChangesBeforeQuitting()
            if reply == .terminateNow { reply = confirmStopCopyingBeforeQuitting() }
        }
        // A cancelled Quit and Keep Windows is forgotten (with the state it
        // saved); a review of the unsaved changes quits again later with
        // the same choice.
        if reply == .terminateCancel, keepWindowsAtQuit {
            keepWindowsAtQuit = false
            StateRestoration.discard()
        }
        return reply
    }

    /// Quitting while three-way merges are open and not resolved (or have
    /// unsaved changes) asks first: quitting ends them unresolved.
    private func confirmEndingMergesBeforeQuitting() -> Bool {
        let open = ipc?.merges.values.filter { !$0.session.isResolved && $0.session.result != nil } ?? []
        guard !open.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = open.count == 1
            ? "The merge of \u{201C}\(open[0].session.files.output.lastPathComponent)\u{201D} is not resolved."
            : "\(open.count) merges are not resolved."
        alert.informativeText = "If you quit now, unsaved choices are lost and the tools that started the merges "
            + "treat them as failed."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Quitting with unsaved edits asks first: save them all, review them
    /// one by one, discard them, or cancel. Review ends by asking to quit
    /// again, which then checks the copies.
    private func confirmUnsavedChangesBeforeQuitting() -> NSApplication.TerminateReply {
        let dirty = unsavedComparisons()
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "\u{201C}\(dirty[0].title)\u{201D} has unsaved changes."
            : "\(dirty.count) comparisons have unsaved changes."
        alert.informativeText = "If you quit without saving, your changes will be lost."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Review Changes\u{2026}")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Every save must finish now; one that needs an answer (or
            // fails) cancels the quit and shows why.
            let saved = dirty.map { controller in
                controller.save([.a, .b].filter { controller.session.isDirty($0) }, confirmed: false)
            }
            return saved.allSatisfy { $0 } ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            reviewKeepsWindows = keepWindowsAtQuit
            review(dirty[...], answered: [])
            return .terminateCancel
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Asks about each comparison in turn (Save, Don't Save, Cancel), then
    /// quits if none was cancelled.
    private func review(_ remaining: ArraySlice<ComparisonWindowController>,
                        answered: [ComparisonWindowController]) {
        guard let controller = remaining.first else {
            keepWindowsAtQuit = reviewKeepsWindows
            NSApp.terminate(nil)
            return
        }
        if let host = controller.hostWindow?.windowController as? DocumentWindowController {
            host.select(controller)
        }
        controller.presentingWindow?.makeKeyAndOrderFront(nil)
        controller.confirmClose { [weak self] proceed in
            guard proceed else {
                // Cancelled: earlier "Don't Save" answers no longer hold.
                for earlier in answered { earlier.closingConfirmed = false }
                self?.reviewKeepsWindows = false
                return
            }
            self?.review(remaining.dropFirst(), answered: answered + [controller])
        }
    }

    /// Quitting while folders are being copied asks first; quitting then
    /// stops every copy (each removes its partial item) before the app
    /// ends.
    private func confirmStopCopyingBeforeQuitting() -> NSApplication.TerminateReply {
        let copying = documentWindows.filter(\.isCopying)
        guard !copying.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Prism is still copying files."
        alert.informativeText = "If you quit now, the item being copied is discarded and the remaining items are not copied."
        alert.addButton(withTitle: "Continue Copying")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        var remaining = copying.count
        for window in copying {
            window.stopCopying {
                remaining -= 1
                if remaining == 0 { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopening a windowless instance shows a launch window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindow(nil)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Closes every visible window that can be closed.
    @objc func closeAll(_ sender: Any?) {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.closable) {
            window.performClose(sender)
        }
    }

    /// Zooms every visible window that can be zoomed.
    @objc func zoomAll(_ sender: Any?) {
        for window in NSApp.windows where window.isVisible && window.isZoomable {
            window.performZoom(sender)
        }
    }

    /// The project's online documentation (the README).
    nonisolated static let helpURL = URL(string: "https://github.com/pditommaso/prism-diff#readme")!

    /// Help > Prism Help: the built-in Help window.
    @objc func openHelp(_ sender: Any?) {
        helpController.present()
    }

    nonisolated static let websiteURL = URL(string: "https://github.com/pditommaso/prism-diff")!
    nonisolated static let feedbackURL = URL(string: "https://github.com/pditommaso/prism-diff/issues/new")!

    /// Help > Prism Website.
    @objc func openWebsite(_ sender: Any?) { NSWorkspace.shared.open(Self.websiteURL) }
    /// Help > Getting Started: the Help window on opening a comparison.
    @objc func showGettingStarted(_ sender: Any?) { helpController.present(topicID: HelpBook.gettingStartedID) }
    /// Help > Send Feedback: a new issue on the project's tracker.
    @objc func sendFeedback(_ sender: Any?) { NSWorkspace.shared.open(Self.feedbackURL) }

    /// Shows the About window, reusing a single instance.
    @objc func showAbout(_ sender: Any?) {
        aboutController.present()
    }
}

/// What the command line asks for: `Prism [--change N] [--no-about] A B`.
/// Options AppKit adds (`-psn_...`, `-Key value` defaults) are skipped.
struct LaunchRequest: Equatable, Sendable {
    var paths: [String] = []
    /// 1-based change to select first (used by tests and benchmarks).
    var initialChange: Int?

    static func parse(_ arguments: [String]) -> LaunchRequest {
        var request = LaunchRequest()
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            if argument == "--change" {
                request.initialChange = rest.popFirst().flatMap { Int($0) }
            } else if argument.hasPrefix("-psn_") || argument.hasPrefix("--") {
                continue
            } else if argument.hasPrefix("-"), argument.count > 1 {
                _ = rest.popFirst() // -Key value (argument domain of the user defaults)
            } else {
                request.paths.append(argument)
            }
        }
        return request
    }
}
