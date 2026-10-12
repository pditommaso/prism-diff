// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismIntegration

/// The Integration window: a list of integrations on the left (the
/// command-line tools, git, Mercurial, Subversion, Perforce) and the
/// selected one's instructions and controls on the right.
@MainActor
final class IntegrationWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    enum Section: Int, CaseIterable {
        case commandLine, git, mercurial, subversion, perforce

        var title: String {
            switch self {
            case .commandLine: "prism"
            case .git: "Git"
            case .mercurial: "Mercurial"
            case .subversion: "Subversion"
            case .perforce: "Perforce"
            }
        }

        var subtitle: String {
            switch self {
            case .commandLine: "Command-line tool"
            case .git: "git difftool, mergetool"
            case .mercurial: "hg extdiff"
            case .subversion: "svn diff"
            case .perforce: "p4 and P4V"
            }
        }

        var symbol: String {
            switch self {
            case .commandLine: "terminal"
            case .git: "arrow.triangle.branch"
            case .mercurial: "drop"
            case .subversion: "externaldrive.connected.to.line.below"
            case .perforce: "square.stack.3d.up"
            }
        }
    }

    static let size = NSSize(width: 700, height: 502)
    static let listWidth: CGFloat = 230

    let environment: IntegrationEnvironment
    let list = NSTableView()
    private let detail = NSView()
    private(set) var destination: URL
    private(set) var gitMode: GitConfigInstaller.Mode = .defaultTool
    private var section: Section = .commandLine

    init(environment: IntegrationEnvironment = .current()) {
        self.environment = environment
        destination = environment.preferredDestination()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Integration"
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("prism.integration")
        super.init(window: window)

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.listWidth, height: Self.size.height))
        scroll.autoresizingMask = [.height]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.width = Self.listWidth
        list.addTableColumn(column)
        list.headerView = nil
        list.style = .sourceList
        list.rowHeight = 52
        list.dataSource = self
        list.delegate = self
        list.allowsEmptySelection = false
        list.setAccessibilityLabel("Integrations")
        scroll.documentView = list
        scroll.drawsBackground = false
        content.addSubview(scroll)
        let separator = NSBox(frame: NSRect(x: Self.listWidth, y: 0, width: 1, height: Self.size.height))
        separator.boxType = .separator
        content.addSubview(separator)
        detail.frame = NSRect(x: Self.listWidth + 1, y: 0, width: Self.size.width - Self.listWidth - 1, height: Self.size.height)
        content.addSubview(detail)
        window.contentView = content
        list.reloadData()
        list.selectRowIndexes([0], byExtendingSelection: false)
        showSection(.commandLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: state

    var toolState: CommandLineToolInstaller.State {
        environment.installer(destination: destination).state()
    }

    var gitInstaller: GitConfigInstaller? {
        environment.gitInstaller(toolCommand: environment.toolCommand(state: toolState))
    }

    func gitStatus(_ mode: GitConfigInstaller.Mode) -> GitConfigInstaller.Status? {
        try? gitInstaller?.status(mode)
    }

    private func isInstalled(_ section: Section) -> Bool {
        switch section {
        case .commandLine:
            if case .installed = toolState { return true }
            return false
        case .git:
            return gitStatus(.availableTool) == .installed
        default:
            return false
        }
    }

    /// Re-reads the state and redraws the list and the selected section.
    func refresh() {
        let row = list.selectedRow
        list.reloadData()
        list.selectRowIndexes([max(row, 0)], byExtendingSelection: false)
        showSection(section)
    }

    // MARK: list

    func numberOfRows(in tableView: NSTableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = Section.allCases[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: section.title)
        title.font = .boldSystemFont(ofSize: 14)
        let subtitle = NSTextField(labelWithString: section.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Installed") ?? NSImage())
        check.contentTintColor = .systemGreen
        check.isHidden = !isInstalled(section)
        for view in [icon, title, subtitle, check] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.textField = title
        cell.setAccessibilityLabel("\(section.title), \(section.subtitle)\(check.isHidden ? "" : ", installed")")
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 2),
            check.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -30),
            check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard list.selectedRow >= 0 else { return }
        showSection(Section.allCases[list.selectedRow])
    }

    // MARK: detail

    private func showSection(_ section: Section) {
        self.section = section
        detail.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        let views: [NSView] = switch section {
        case .commandLine: commandLineViews()
        case .git: gitViews()
        case .mercurial: mercurialViews()
        case .subversion: subversionViews()
        case .perforce: perforceViews()
        }
        views.forEach(stack.addArrangedSubview)
        for view in views { view.widthAnchor.constraint(lessThanOrEqualToConstant: detail.bounds.width - 56).isActive = true }
        stack.frame = detail.bounds
        stack.autoresizingMask = [.width, .height]
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        let flipped = FlippedView(frame: detail.bounds)
        flipped.autoresizingMask = [.width, .height]
        flipped.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
        ])
        detail.addSubview(flipped)
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 18)
        return field
    }

    private func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.preferredMaxLayoutWidth = detail.bounds.width - 56
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Monospaced text in a rounded box.
    private func code(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = detail.bounds.width - 80
        return box(containing: [field])
    }

    /// A rounded box holding one row of views.
    private func box(containing views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.borderWidth = 1
        row.layer?.borderColor = NSColor.separatorColor.cgColor
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        row.widthAnchor.constraint(equalToConstant: detail.bounds.width - 56).isActive = true
        return row
    }

    private func stepNumber(_ number: Int) -> NSView {
        let field = NSTextField(labelWithString: "\(number)")
        field.font = .boldSystemFont(ofSize: 12)
        field.alignment = .center
        field.textColor = .white
        field.wantsLayer = true
        field.layer?.cornerRadius = 10
        field.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 20).isActive = true
        field.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return field
    }

    private func button(_ title: String, _ action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    // MARK: prism section

    private func commandLineViews() -> [NSView] {
        let state = toolState
        let installer = environment.installer(destination: destination)
        let status: String
        let action: NSButton
        switch state {
        case .installed(let url):
            status = url.lastPathComponent == CommandLineToolInstaller.toolName
                ? "prism is installed in \(url.deletingLastPathComponent().path)"
                : "Installed as \(url.lastPathComponent) in \(url.deletingLastPathComponent().path)"
            action = button("Remove\u{2026}", #selector(removeTools(_:)), identifier: "prism.integration.prism.remove")
        case .foreign(let foreign):
            status = "The prism in \(destination.path) belongs to \(foreign.ownerName ?? "another application")"
            action = button("Install\u{2026}", #selector(installTools(_:)), identifier: "prism.integration.prism.install")
        case .notInstalled:
            status = "prism is not installed"
            action = button("Install\u{2026}", #selector(installTools(_:)), identifier: "prism.integration.prism.install")
        }
        let statusField = NSTextField(labelWithString: status)
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.setAccessibilityIdentifier("prism.integration.prism.status")
        var warning: NSTextField?
        if let shadow = installer.shadowing() {
            let owner = shadow.ownerName ?? "another application"
            warning = paragraph("Note: \(shadow.path.path) (from \(owner)) comes first on your PATH, so typing prism runs that one.")
        } else if case .notInstalled = state, let other = installer.foreignTool() {
            let owner = other.ownerName ?? "another application"
            warning = paragraph("Note: \(other.path.path) (from \(owner)) is also named prism. Prism's tool can be installed as \(CommandLineToolInstaller.alternateName) instead.")
        }
        warning?.textColor = .systemOrange
        warning?.setAccessibilityIdentifier("prism.integration.prism.shadowed")
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        action.keyEquivalent = "\r"

        var views: [NSView] = [
            heading("The prism Command-Line Tool"),
            paragraph("prism opens files and folders in Prism from Terminal, and lets git, Mercurial, Subversion and Perforce show their changes in Prism. It accepts the same options as ksdiff. prism diff, prism sniff and prism merge3 compare files without the app."),
            box(containing: [stepNumber(1), statusField, flexibleSpace(), action]),
        ]
        if let warning { views.append(warning) }
        if environment.destinations.count > 1 {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for folder in environment.destinations {
                popup.addItem(withTitle: (folder.path as NSString).abbreviatingWithTildeInPath)
                popup.lastItem?.representedObject = folder
            }
            popup.selectItem(at: environment.destinations.firstIndex(of: destination) ?? 0)
            popup.target = self
            popup.action = #selector(chooseDestination(_:))
            popup.isEnabled = { if case .installed = state { false } else { true } }()
            let label = NSTextField(labelWithString: "Install in:")
            views.append(NSStackView(views: [label, popup]))
        }
        views += [
            caption("Example:"),
            code("prism ~/Documents/draft-1.txt ~/Documents/draft-2.txt"),
        ]
        return views
    }

    @objc private func chooseDestination(_ sender: NSPopUpButton) {
        if let folder = sender.selectedItem?.representedObject as? URL {
            destination = folder
            refresh()
        }
    }

    @objc func installTools(_ sender: Any?) {
        let installer = environment.installer(destination: destination)
        do {
            try installer.install()
        } catch .conflict(let foreign) {
            offerAlternateName(foreign, installer: installer)
            return
        } catch {
            report(error, installer: installer)
        }
        refresh()
    }

    /// Another application's prism is present: offer `prism-diff` instead;
    /// never overwrites or shadows the other program.
    private func offerAlternateName(_ foreign: CommandLineToolInstaller.ForeignTool, installer: CommandLineToolInstaller) {
        let owner = foreign.ownerName ?? "another application"
        let alternate = CommandLineToolInstaller.alternateName
        let alert = NSAlert()
        alert.messageText = "Another prism is already installed."
        alert.informativeText = """
            \(foreign.path.path) belongs to \(owner). Prism leaves it alone and can install its own tool as \(alternate).
            """
        alert.addButton(withTitle: "Install as \(alternate)")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do throws(CommandLineToolInstaller.Failure) {
                let url = try installer.install(alternate: true)
                PerfLog.record("integrationInstall", ["link": url.lastPathComponent])
            } catch {
                self.report(error, installer: installer)
            }
            self.refresh()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    @objc func removeTools(_ sender: Any?) {
        let installer = environment.installer(destination: destination)
        do {
            try installer.uninstall()
        } catch {
            report(error, installer: installer)
        }
        refresh()
    }

    private func report(_ error: CommandLineToolInstaller.Failure, installer: CommandLineToolInstaller) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The command-line tools could not be changed."
        var details = error.description
        if case .fileSystem = error, installer.destination.path == "/usr/local/bin" {
            let helper = installer.helper.path
            details += "\n\nChoose ~/bin instead, or link the tool yourself in Terminal:\nsudo ln -sf '\(helper)' /usr/local/bin/prism"
        }
        alert.informativeText = details
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: git section

    private func gitViews() -> [NSView] {
        var views: [NSView] = [
            heading("Git"),
            paragraph("With Prism as git's diff tool, git difftool opens every changed file in one window, with the files listed on the left."),
            paragraph("As git's merge tool, git mergetool opens each conflicted file in a three-way merge. Save the result with every conflict resolved, then close the window: git marks the file resolved. Closing without resolving leaves the conflict to git."),
        ]
        guard gitInstaller != nil else {
            views.append(paragraph("git was not found. Install the Xcode Command Line Tools or git, then reopen this window."))
            return views
        }
        let defaultMode = NSButton(radioButtonWithTitle: "Make Prism git's default diff and merge tool",
                                   target: self, action: #selector(chooseGitMode(_:)))
        defaultMode.tag = 0
        defaultMode.state = gitMode == .defaultTool ? .on : .off
        let availableMode = NSButton(radioButtonWithTitle: "Add Prism as an extra diff and merge tool, used with -t prism",
                                     target: self, action: #selector(chooseGitMode(_:)))
        availableMode.tag = 1
        availableMode.state = gitMode == .availableTool ? .on : .off
        views += [defaultMode, availableMode]

        let status = gitStatus(gitMode)
        let text: String
        var buttons: [NSButton] = []
        switch status {
        case .installed:
            text = "Git is set up to use Prism"
            buttons.append(button("Remove", #selector(removeGit(_:)), identifier: "prism.integration.git.remove"))
        case .needsUpdate:
            text = "Git's Prism command is out of date"
            buttons.append(button("Update", #selector(installGit(_:)), identifier: "prism.integration.git.install"))
            buttons.append(button("Remove", #selector(removeGit(_:)), identifier: "prism.integration.git.remove"))
        case .notInstalled, nil:
            text = "Git is not set up to use Prism"
            buttons.append(button("Install", #selector(installGit(_:)), identifier: "prism.integration.git.install"))
            if gitStatus(.availableTool) == .installed {
                buttons.append(button("Remove", #selector(removeGit(_:)), identifier: "prism.integration.git.remove"))
            }
        }
        let statusField = NSTextField(labelWithString: text)
        statusField.setAccessibilityIdentifier("prism.integration.git.status")
        views.append(box(containing: [stepNumber(1), statusField, flexibleSpace()] + buttons))
        views += [
            caption("Example:"),
            code(gitMode == .defaultTool ? "git difftool\ngit mergetool" : "git difftool -t prism\ngit mergetool -t prism"),
            paragraph("Prism changes only its own entries in your global git configuration (git config --global); removing them restores what was there before."),
        ]
        return views
    }

    @objc private func chooseGitMode(_ sender: NSButton) {
        gitMode = sender.tag == 0 ? .defaultTool : .availableTool
        showSection(.git)
    }

    @objc func installGit(_ sender: Any?) {
        guard let installer = gitInstaller else { return }
        do {
            try installer.install(gitMode)
            PerfLog.record("integrationGit", ["action": "install", "mode": gitMode.rawValue])
        } catch {
            reportGit(error)
        }
        refresh()
    }

    @objc func removeGit(_ sender: Any?) {
        guard let installer = gitInstaller else { return }
        do {
            try installer.uninstall()
            PerfLog.record("integrationGit", ["action": "remove"])
        } catch {
            reportGit(error)
        }
        refresh()
    }

    private func reportGit(_ error: GitConfigInstaller.Failure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Git could not be configured."
        alert.informativeText = error.description
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: manual integrations

    private func mercurialViews() -> [NSView] {
        [
            heading("Mercurial"),
            paragraph("Mercurial's extdiff extension can send a whole set of changes to Prism at once. Add this to ~/.hgrc:"),
            code("[extensions]\nextdiff =\n\n[extdiff]\ncmd.prism = prism\nopts.prism = --changeset --wait --filelist"),
            caption("Example:"),
            code("hg prism"),
        ]
    }

    private func subversionViews() -> [NSView] {
        [
            heading("Subversion"),
            paragraph("prism understands the arguments svn passes to an external diff program. Add this to the [helpers] section of ~/.subversion/config:"),
            code("diff-cmd = prism"),
            paragraph("or use it for one command only:"),
            code("svn diff --diff-cmd prism"),
        ]
    }

    private func perforceViews() -> [NSView] {
        [
            heading("Perforce"),
            paragraph("For p4 in Terminal, set the diff program in your shell profile:"),
            code("export P4DIFF=prism"),
            paragraph("In P4V, open Preferences, Diff, choose Other application, and enter prism as the application with %1 %2 as its arguments."),
        ]
    }
}

/// A container with a top-left origin.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
