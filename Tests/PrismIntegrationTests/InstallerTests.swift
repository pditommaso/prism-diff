// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismTestSupport
@testable import PrismIntegration

// Installer tests work only inside temporary folders: a fake app bundle, a
// temporary bin folder as the destination, and a sandboxed git config.
// Nothing touches /usr/local/bin, ~/bin or the user's ~/.gitconfig.

private struct ToolBench {
    let directory: TemporaryDirectory
    let helpers: URL
    let bin: URL

    init() throws {
        directory = try TemporaryDirectory(prefix: "prism-install")
        helpers = directory.url.appending(path: "Prism.app/Contents/Helpers", directoryHint: .isDirectory)
        bin = directory.url.appending(path: "prefix/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try makeScript(helpers.appending(path: "prism"), "echo prism")
    }

    func makeScript(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    func installer(searchPath: [URL] = []) -> CommandLineToolInstaller {
        CommandLineToolInstaller(helpersDirectory: helpers, destination: bin, searchPath: searchPath)
    }

    /// A `prism` of another application, linked into the bin folder.
    func foreignTool(app: String = "Other Tool") throws -> URL {
        let real = directory.url.appending(path: "Applications/\(app).app/Contents/Resources/bin/prism")
        try makeScript(real, "echo foreign")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appending(path: "prism")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return real
    }

    func target(of name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: name).path)
    }
}

@Suite struct CommandLineToolInstallerTests {
    @Test func installsSilentlyWhenNothingIsThere() throws {
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        let installer = bench.installer()
        #expect(installer.state() == .notInstalled)
        let link = bench.bin.appending(path: "prism")
        #expect(try installer.install() == link)
        #expect(bench.target(of: "prism") == bench.helpers.appending(path: "prism").path)
        #expect(installer.state() == .installed(link))
        // Installing again is harmless.
        #expect(try installer.install() == link)
        try installer.uninstall()
        #expect(installer.state() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test func foreignToolInTheDestinationIsAConflict() throws {
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        let real = try bench.foreignTool()
        let installer = bench.installer()
        guard case .foreign(let foreign) = installer.state() else {
            Issue.record("not detected as foreign: \(installer.state())")
            return
        }
        #expect(foreign.ownerName == "Other Tool")
        #expect(foreign.resolvedPath.path == real.resolvingSymlinksInPath().path)
        #expect(throws: CommandLineToolInstaller.Failure.conflict(foreign)) { try installer.install() }
        // Nothing was changed.
        #expect(bench.target(of: "prism") == real.path)
    }

    @Test func alternateNameInstallsNextToTheForeignTool() throws {
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        let real = try bench.foreignTool()
        let installer = bench.installer()
        let alternate = bench.bin.appending(path: "prism-diff")
        #expect(try installer.install(alternate: true) == alternate)
        #expect(bench.target(of: "prism") == real.path)
        #expect(installer.state() == .installed(alternate))
        try installer.uninstall()
        #expect(bench.target(of: "prism-diff") == nil)
        #expect(bench.target(of: "prism") == real.path)
        #expect(installer.state() != .notInstalled)     // the foreign one remains
    }

    @Test func anotherPrismOnThePathIsAConflict() throws {
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        let otherFolder = bench.directory.url.appending(path: "other/bin")
        let other = otherFolder.appending(path: "prism")
        try bench.makeScript(other, "echo someone else")
        let installer = bench.installer(searchPath: [otherFolder])
        #expect(installer.foreignTool()?.path == other)
        #expect(throws: CommandLineToolInstaller.Failure.self) { try installer.install() }
        #expect(!FileManager.default.fileExists(atPath: bench.bin.appending(path: "prism").path))
        #expect(try installer.install(alternate: true) == bench.bin.appending(path: "prism-diff"))
        // Without another prism it takes the plain name, and only one name is kept.
        #expect(try bench.installer().install() == bench.bin.appending(path: "prism"))
        #expect(bench.target(of: "prism-diff") == nil)
    }

    @Test func foreignToolEarlierOnPathIsReported() throws {
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        let early = bench.directory.url.appending(path: "early/bin")
        try bench.makeScript(early.appending(path: "prism"), "echo other")
        try bench.installer().install()
        let installer = bench.installer(searchPath: [early, bench.bin])
        #expect(installer.shadowing()?.path == early.appending(path: "prism"))
        // Later on the path does not count.
        #expect(bench.installer(searchPath: [bench.bin, early]).shadowing() == nil)
    }

    @Test func missingHelperIsReported() throws {
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        try FileManager.default.removeItem(at: bench.helpers.appending(path: "prism"))
        #expect(throws: CommandLineToolInstaller.Failure.missingHelper(bench.helpers.appending(path: "prism"))) {
            try bench.installer().install()
        }
    }

    @Test func signedPrismToolCountsAsOurs() throws {
        // The bundled helper is signed with Prism's identifier; any copy of
        // it (an older app, say) is Prism's tool, not a foreign one.
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        guard let built = BuildProducts.executable("prism") else { return }
        let copy = bench.bin.appending(path: "prism")
        try FileManager.default.createDirectory(at: bench.bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", "io.github.pditommaso.prism.tool", copy.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        #expect(CommandLineToolInstaller.signingIdentifier(of: copy) == "io.github.pditommaso.prism.tool")
        #expect(bench.installer().state() == .installed(copy))
    }

    @Test func aLinkToADeletedCopyIsReplaced() throws {
        // An earlier install from a copy of Prism that was since deleted.
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        try FileManager.default.createDirectory(at: bench.bin, withIntermediateDirectories: true)
        let link = bench.bin.appending(path: "prism")
        let gone = bench.directory.url.appending(path: "Deleted/Prism.app/Contents/Helpers/prism")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gone)
        let installer = bench.installer()
        #expect(installer.state() == .notInstalled)
        #expect(try installer.install() == link)
        #expect(bench.target(of: "prism") == bench.helpers.appending(path: "prism").path)
        #expect(installer.state() == .installed(link))
    }

    @Test func aLinkToAnotherPrismCopyIsRepointed() throws {
        // An earlier install from another (older) copy of the app.
        let bench = try ToolBench()
        defer { bench.directory.remove() }
        guard let built = BuildProducts.executable("prism") else { return }
        let older = bench.directory.url.appending(path: "Older/Prism.app/Contents/Helpers/prism")
        try FileManager.default.createDirectory(at: older.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: older)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", "io.github.pditommaso.prism.tool", older.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try FileManager.default.createDirectory(at: bench.bin, withIntermediateDirectories: true)
        let link = bench.bin.appending(path: "prism")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: older)
        let installer = bench.installer()
        #expect(installer.state() == .notInstalled)
        #expect(try installer.install() == link)
        #expect(bench.target(of: "prism") == bench.helpers.appending(path: "prism").path)
        #expect(installer.state() == .installed(link))
        // The older copy itself is left alone.
        #expect(FileManager.default.fileExists(atPath: older.path))
    }
}

// MARK: - git config

private struct GitBench {
    let sandbox: GitSandbox
    let installer: GitConfigInstaller

    init(prism: String = "prism") throws {
        sandbox = try GitSandbox()
        installer = GitConfigInstaller(
            git: URL(fileURLWithPath: "/usr/bin/git"),
            toolCommand: prism,
            environment: sandbox.environment(),
            stateFile: sandbox.root.appending(path: "state/git-integration.json")
        )
    }

    var config: String {
        (try? String(contentsOf: sandbox.globalConfig, encoding: .utf8)) ?? ""
    }

    func setConfig(_ text: String) throws {
        try text.write(to: sandbox.globalConfig, atomically: true, encoding: .utf8)
    }

    func get(_ key: String) -> String? {
        let result = try? sandbox.git(["config", "--global", "--get", key])
        guard let result, result.status == 0 else { return nil }
        return String(result.output.dropLast())
    }
}

private let expectedCommand = "prism --partial-changeset --relative-path \"$MERGED\" -- \"$LOCAL\" \"$REMOTE\""
private let expectedMergeCommand =
    "prism --merge --output \"$MERGED\" --base \"$BASE\" -- \"$LOCAL\" --snapshot \"$REMOTE\" --snapshot"

@Suite struct GitConfigInstallerTests {
    @Test func defaultToolInstallWritesTheKeys() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        #expect(try bench.installer.status(.defaultTool) == .notInstalled)
        try bench.installer.install(.defaultTool)
        #expect(bench.get("difftool.prism.cmd") == expectedCommand)
        #expect(bench.get("diff.tool") == "prism")
        #expect(bench.get("difftool.prompt") == "false")
        #expect(try bench.installer.status(.defaultTool) == .installed)
        #expect(try bench.installer.status(.availableTool) == .installed)
    }

    @Test func mergetoolKeysAreWrittenInBothModes() throws {
        for mode in GitConfigInstaller.Mode.allCases {
            let bench = try GitBench()
            defer { bench.sandbox.remove() }
            try bench.installer.install(mode)
            #expect(bench.get("mergetool.prism.cmd") == expectedMergeCommand)
            #expect(bench.get("mergetool.prism.trustExitCode") == "true")
            #expect(bench.get("merge.tool") == (mode == .defaultTool ? "prism" : nil))
            #expect(bench.get("mergetool.prompt") == (mode == .defaultTool ? "false" : nil))
        }
    }

    @Test func anOlderInstallWithoutTheMergetoolNeedsUpdate() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        try bench.setConfig("[difftool \"prism\"]\n\tcmd = \(expectedCommand.replacingOccurrences(of: "\"", with: "\\\""))\n")
        #expect(bench.get("difftool.prism.cmd") == expectedCommand)
        #expect(try bench.installer.status(.availableTool) == .needsUpdate)
        try bench.installer.install(.availableTool)
        #expect(try bench.installer.status(.availableTool) == .installed)
    }

    @Test func anotherToolsMergetoolEntriesSurviveByteForByte() throws {
        // Like a global config that already sets up another diff tool.
        let original = """
            [difftool "Other"]
            \tcmd = other-diff --partial-changeset --relative-path \"$MERGED\" -- \"$LOCAL\" \"$REMOTE\"
            [diff]
            \ttool = Other
            [mergetool "Other"]
            \tcmd = other-diff --merge --output \"$MERGED\" --base \"$BASE\" -- \"$LOCAL\" \"$REMOTE\"
            \ttrustExitCode = true
            [merge]
            \ttool = Other
            [mergetool]
            \tprompt = false

            """
        for mode in GitConfigInstaller.Mode.allCases {
            let bench = try GitBench()
            defer { bench.sandbox.remove() }
            try bench.setConfig(original)
            try bench.installer.install(mode)
            #expect(bench.get("mergetool.Other.cmd")?.hasPrefix("other-diff --merge") == true)
            #expect(bench.get("merge.tool") == (mode == .defaultTool ? "prism" : "Other"))
            try bench.installer.uninstall()
            #expect(bench.config == original, "mode \(mode)")
        }
    }

    @Test func removeAfterAnEditRemovesTheMergetoolKeysToo() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        try bench.setConfig("[merge]\n\ttool = vimdiff\n")
        try bench.installer.install(.defaultTool)
        _ = try bench.sandbox.git(["config", "--global", "core.editor", "vim"])
        try bench.installer.uninstall()
        #expect(bench.get("mergetool.prism.cmd") == nil)
        #expect(bench.get("mergetool.prism.trustExitCode") == nil)
        #expect(bench.get("merge.tool") == "vimdiff")
        #expect(bench.get("mergetool.prompt") == nil)
        #expect(bench.get("core.editor") == "vim")
    }

    @Test func availableToolLeavesTheDefaultAlone() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        try bench.setConfig("[diff]\n\ttool = vimdiff\n")
        try bench.installer.install(.availableTool)
        #expect(bench.get("difftool.prism.cmd") == expectedCommand)
        #expect(bench.get("diff.tool") == "vimdiff")
        #expect(try bench.installer.status(.availableTool) == .installed)
        #expect(try bench.installer.status(.defaultTool) == .notInstalled)
    }

    @Test(arguments: [
        "",
        "[user]\n\tname = Someone\n\temail = someone@example.com\n",
        "[user]\n\tname = X\n[diff]\n\tcolorMoved = zebra\n\ttool = vimdiff\n[alias]\n\tst = status\n",
        "# my settings\n[difftool]\n\tprompt = true\n[difftool \"other\"]\n\tcmd = other \"$LOCAL\" \"$REMOTE\"\n[core]\n\teditor = vim\n",
        "[diff]\n\ttool = prism\n",   // left over by hand
    ])
    func removeRestoresTheConfigByteForByte(original: String) throws {
        for mode in GitConfigInstaller.Mode.allCases {
            let bench = try GitBench()
            defer { bench.sandbox.remove() }
            try bench.setConfig(original)
            try bench.installer.install(mode)
            #expect(try bench.installer.status(mode) == .installed)
            #expect(bench.config != original)
            try bench.installer.uninstall()
            #expect(bench.config == original, "mode \(mode)")
            #expect(try bench.installer.status(mode) == .notInstalled)
        }
    }

    @Test func installingBothModesThenRemovingRestores() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        let original = "[diff]\n\ttool = meld\n"
        try bench.setConfig(original)
        try bench.installer.install(.availableTool)
        try bench.installer.install(.defaultTool)
        try bench.installer.uninstall()
        #expect(bench.config == original)
    }

    @Test func changedCommandNeedsUpdate() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        try bench.setConfig("[difftool \"prism\"]\n\tcmd = /old/prism \"$LOCAL\" \"$REMOTE\"\n")
        #expect(try bench.installer.status(.availableTool) == .needsUpdate)
        try bench.installer.install(.availableTool)
        #expect(try bench.installer.status(.availableTool) == .installed)
    }

    @Test func keysChangedByTheUserAreLeftAlone() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        try bench.installer.install(.defaultTool)
        _ = try bench.sandbox.git(["config", "--global", "diff.tool", "meld"])
        try bench.installer.uninstall()
        #expect(bench.get("diff.tool") == "meld")
        #expect(bench.get("difftool.prism.cmd") == nil)
        #expect(bench.get("difftool.prompt") == nil)
    }

    @Test func commandNameIsQuotedWhenNeeded() {
        #expect(GitConfigInstaller.difftoolCommand(tool: "prism-diff").hasPrefix("prism-diff --partial-changeset"))
        #expect(GitConfigInstaller.difftoolCommand(tool: "/Users/me/my bin/prism").hasPrefix("'/Users/me/my bin/prism' --"))
        #expect(GitConfigInstaller.shellQuoted("it's") == "'it'\\''s'")
    }

    @Test func installedCommandWorksWithGitDifftool() throws {
        // The written command, run by git, reaches the given prism.
        let bench = try GitBench(prism: "")
        defer { bench.sandbox.remove() }
        let recorder = bench.sandbox.root.appending(path: "bin/fake-prism")
        try FileManager.default.createDirectory(at: recorder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let log = bench.sandbox.root.appending(path: "calls.log")
        try "#!/bin/sh\nprintf '%s|' \"$@\" >> '\(log.path)'\necho >> '\(log.path)'\n".write(to: recorder, atomically: true, encoding: .utf8)
        chmod(recorder.path, 0o755)
        let installer = GitConfigInstaller(git: bench.installer.git, toolCommand: recorder.path,
                                           environment: bench.installer.environment, stateFile: bench.installer.stateFile)
        try installer.install(.defaultTool)
        let repository = try bench.sandbox.makeFixtureRepository()
        let result = try bench.sandbox.git(["difftool"], in: repository)
        #expect(result.status == 0, "\(result.error)")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 2)
        #expect(calls.first?.hasPrefix("--partial-changeset|--relative-path|conf.ini|--|") == true)
        #expect(calls.first?.hasSuffix("|conf.ini|") == true)
    }

    // Regression tests from the M5 check.

    @Test func removeAfterTheToolCommandChangedRemovesEverything() throws {
        let bench = try GitBench(prism: "/Applications/Prism.app/Contents/Helpers/prism")
        defer { bench.sandbox.remove() }
        let before = "[user]\n\tname = Someone\n[diff]\n\ttool = vimdiff\n"
        try bench.setConfig(before)
        try bench.installer.install(.defaultTool)
        // The CLI was linked meanwhile, so the window now says "prism".
        let later = GitConfigInstaller(git: bench.installer.git, toolCommand: "prism",
                                       environment: bench.installer.environment, stateFile: bench.installer.stateFile)
        try later.uninstall()
        #expect(bench.config == before)
        #expect(!FileManager.default.fileExists(atPath: bench.installer.stateFile.path))
    }

    @Test func removeAfterAnEditStillRemovesThePrismKeys() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        try bench.setConfig("[diff]\n\ttool = vimdiff\n")
        try bench.installer.install(.defaultTool)
        _ = try bench.sandbox.git(["config", "--global", "core.editor", "vim"])
        let later = GitConfigInstaller(git: bench.installer.git, toolCommand: "/elsewhere/prism",
                                       environment: bench.installer.environment, stateFile: bench.installer.stateFile)
        try later.uninstall()
        #expect(bench.get("difftool.prism.cmd") == nil)
        #expect(bench.get("diff.tool") == "vimdiff")
        #expect(bench.get("difftool.prompt") == nil)
        #expect(bench.get("core.editor") == "vim")
    }

    @Test func includedValuesAreNotCopiedIntoTheFile() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        let included = bench.sandbox.root.appending(path: "inc.gitconfig")
        try "[diff]\n\ttool = vimdiff\n".write(to: included, atomically: true, encoding: .utf8)
        let before = "[include]\n\tpath = \(included.path)\n"
        try bench.setConfig(before)
        try bench.installer.install(.defaultTool)
        try bench.installer.uninstall()
        #expect(bench.config == before)
    }

    @Test func handFormattingAndCommentsSurvive() throws {
        let bench = try GitBench()
        defer { bench.sandbox.remove() }
        let before = "[diff]\n    tool = vimdiff   ; my choice\n[difftool]\n    prompt = true\n"
        try bench.setConfig(before)
        try bench.installer.install(.defaultTool)
        try bench.installer.uninstall()
        #expect(bench.config == before)
    }

    @Test func aMissingConfigFileIsMissingAgain() throws {
        for mode in GitConfigInstaller.Mode.allCases {
            let bench = try GitBench()
            defer { bench.sandbox.remove() }
            try FileManager.default.removeItem(at: bench.sandbox.globalConfig)
            try bench.installer.install(mode)
            #expect(FileManager.default.fileExists(atPath: bench.sandbox.globalConfig.path))
            try bench.installer.uninstall()
            #expect(!FileManager.default.fileExists(atPath: bench.sandbox.globalConfig.path), "mode \(mode)")
        }
    }

    @Test func missingGitIsReported() throws {
        let installer = GitConfigInstaller(git: URL(fileURLWithPath: "/nonexistent/git"), toolCommand: "prism",
                                           environment: [:], stateFile: URL(fileURLWithPath: "/nonexistent/state"))
        #expect(throws: GitConfigInstaller.Failure.gitNotFound) { try installer.status(.defaultTool) }
    }
}
