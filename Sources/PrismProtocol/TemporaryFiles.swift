// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Decides whether a file named on the command line is temporary: owned by
/// the calling tool, which may delete it as soon as `prism` returns (git
/// removes its blob copies right after the diff tool exits). The app copies
/// temporary files before it replies.
public struct TemporaryFileRule: Sendable {
    /// Directory prefixes whose contents count as temporary.
    public var prefixes: [String]

    /// The standard prefixes plus the caller's `TMPDIR`.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var prefixes = ["/tmp/", "/private/tmp/", "/var/", "/private/var/"]
        for directory in [environment["TMPDIR"], NSTemporaryDirectory()].compactMap({ $0 }) where !directory.isEmpty {
            prefixes.append(directory.hasSuffix("/") ? directory : directory + "/")
        }
        self.prefixes = prefixes
    }

    public init(prefixes: [String]) {
        self.prefixes = prefixes
    }

    /// Path fragments of the scratch areas of other version-control tools.
    static let markers = ["-Tmp-", ".svn/tmp/", ".svn/text-base/"]

    /// True when `path` (absolute) is a temporary file.
    public func isTemporary(_ path: String) -> Bool {
        if path == IPCProtocol.placeholderPath { return false }
        if prefixes.contains(where: { path.hasPrefix($0) }) { return true }
        if Self.markers.contains(where: { path.contains($0) }) { return true }
        return Self.hasHashedDirectory(path)
    }

    /// Mercurial's extdiff copies revisions into directories named
    /// `<repo>.<12 hex digits>`.
    static func hasHashedDirectory(_ path: String) -> Bool {
        for component in path.split(separator: "/") {
            guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { continue }
            let suffix = component[component.index(after: dot)...]
            if suffix.count == 12, suffix.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
                return true
            }
        }
        return false
    }
}

/// Window titles for changesets.
public enum ChangesetTitle {
    /// The default title for a changeset from `caller`: the caller's
    /// arguments without the tool name and its diff subcommand, as
    /// `“<arguments>” in <folder>`, or `Changes in <folder>` when none are
    /// left. `<folder>` is the last component of the working directory.
    public static func suggested(for caller: CallerInfo) -> String {
        let folder = (caller.workingDirectory as NSString).lastPathComponent
        let remaining = significantArguments(caller)
        if remaining.isEmpty {
            return "Changes in \(folder)"
        }
        return "\u{201C}\(remaining.joined(separator: " "))\u{201D} in \(folder)"
    }

    static let diffSubcommands: Set<String> = ["diff", "difftool", "extdiff"]

    static func significantArguments(_ caller: CallerInfo) -> [String] {
        var args = caller.arguments
        if caller.tool == .mercurial || caller.tool == .bazaar,
           let first = args.first, (first as NSString).lastPathComponent.lowercased().hasPrefix("python") {
            args.removeFirst()          // the interpreter
        }
        guard !args.isEmpty else { return [] }
        args.removeFirst()              // the tool itself
        if let first = args.first, diffSubcommands.contains(first) {
            args.removeFirst()
        }
        if caller.tool == .subversion {
            args.removeAll { $0.hasPrefix("--diff-cmd") }
        }
        return args
    }
}

/// Where the app's socket lives, and the environment that overrides it.
public enum IPCEnvironment {
    /// Overrides the socket path, for `prism` and the app alike. Tests use
    /// it to keep their socket in a temporary directory.
    public static let socketPathVariable = "PRISM_SOCKET_PATH"
    /// The app bundle `prism` launches when the app is not running.
    public static let appPathVariable = "PRISM_APP_PATH"
    /// Set by `prism` (to its PID) when it launches the app, which then
    /// shows no window of its own at launch.
    public static let launchedByCLIVariable = "PRISM_LAUNCHED_BY_CLI"
    /// Set to "1" by tests: test-only overrides take effect and the app
    /// never brings itself to the front.
    public static let testingVariable = "PRISM_TESTING"
    /// The variables `prism` passes on to an app it starts.
    public static let forwardedVariables: Set<String> = [
        socketPathVariable, testingVariable, "PRISM_PERF_LOG", "PRISM_INTEGRATION_ROOT",
    ]

    /// The socket path for this environment.
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let override = environment[socketPathVariable], !override.isEmpty {
            return override
        }
        return PrismInfo.socketURL(home: home).path
    }
}
