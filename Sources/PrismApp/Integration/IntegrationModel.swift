// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismIntegration
import PrismProtocol

/// Where the Integration window installs things, and with what.
///
/// In debug builds, or with `PRISM_TESTING=1`, `PRISM_INTEGRATION_ROOT` and
/// `PRISM_HELPERS_DIR` are honoured; a release build ignores them otherwise.
/// `PRISM_INTEGRATION_ROOT=<folder>` redirects everything into that folder,
/// for tests: the tools go to `<folder>/bin`, git writes `<folder>/gitconfig`
/// (whatever `GIT_CONFIG_GLOBAL` says) and the saved git values go
/// to `<folder>/git-integration.json`. Without it: `/usr/local/bin` or
/// `~/bin`, the user's global git config, and Application Support.
struct IntegrationEnvironment: Sendable {
    static let rootVariable = "PRISM_INTEGRATION_ROOT"

    var helpersDirectory: URL
    var destinations: [URL]
    var gitEnvironment: [String: String]
    var gitStateFile: URL
    var searchPath: [URL]

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: URL = Bundle.main.bundleURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> IntegrationEnvironment {
        let overrides = allowsTestOverrides(environment)
        let helpers = (overrides ? environment["PRISM_HELPERS_DIR"] : nil).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? bundle.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        var gitEnvironment = environment
        let searchPath = CommandLineToolInstaller.searchPath(from: environment["PATH"])
        if overrides, let root = environment[rootVariable], !root.isEmpty {
            let folder = URL(filePath: root, directoryHint: .isDirectory)
            gitEnvironment["GIT_CONFIG_GLOBAL"] = folder.appending(path: "gitconfig").path
            return IntegrationEnvironment(
                helpersDirectory: helpers,
                destinations: [folder.appending(path: "bin", directoryHint: .isDirectory)],
                gitEnvironment: gitEnvironment,
                gitStateFile: folder.appending(path: "git-integration.json"),
                searchPath: []
            )
        }
        return IntegrationEnvironment(
            helpersDirectory: helpers,
            destinations: CommandLineToolInstaller.standardDestinations(home: home),
            gitEnvironment: gitEnvironment,
            gitStateFile: PrismInfo.socketURL(home: home).deletingLastPathComponent()
                .appending(path: "git-integration.json"),
            searchPath: searchPath
        )
    }

    static func allowsTestOverrides(_ environment: [String: String]) -> Bool {
        #if DEBUG
        return true
        #else
        return environment[IPCEnvironment.testingVariable] == "1"
        #endif
    }

    func installer(destination: URL) -> CommandLineToolInstaller {
        CommandLineToolInstaller(helpersDirectory: helpersDirectory, destination: destination, searchPath: searchPath)
    }

    /// The destination that already holds Prism's `prism`, else the
    /// first one.
    func preferredDestination() -> URL {
        for destination in destinations {
            if case .installed = installer(destination: destination).state() { return destination }
        }
        return destinations[0]
    }

    /// How git should invoke `prism`: its plain name when installed in
    /// `/usr/local/bin` (always on PATH), the full path of the link
    /// otherwise, and the copy inside the app when it is not installed.
    func toolCommand(state: CommandLineToolInstaller.State) -> String {
        guard case .installed(let link) = state else {
            return helpersDirectory.appending(path: CommandLineToolInstaller.toolName).path
        }
        if link.deletingLastPathComponent().standardizedFileURL.path == "/usr/local/bin" {
            return link.lastPathComponent
        }
        return link.path
    }

    func gitInstaller(toolCommand: String) -> GitConfigInstaller? {
        guard let git = GitConfigInstaller.locateGit(environment: gitEnvironment) else { return nil }
        return GitConfigInstaller(git: git, toolCommand: toolCommand,
                                  environment: gitEnvironment, stateFile: gitStateFile)
    }
}
