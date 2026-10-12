// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol

/// Configures git to use Prism as a diff and merge tool, through `git
/// config --global`, under the tool name `prism` (so an existing entry for
/// another tool is never touched).
///
/// Two modes:
/// - `.availableTool` adds `difftool.prism.cmd`, `mergetool.prism.cmd` and
///   `mergetool.prism.trustExitCode = true`, for `git difftool -t prism`
///   and `git mergetool -t prism`;
/// - `.defaultTool` also sets `diff.tool` and `merge.tool` to `prism` and
///   `difftool.prompt` and `mergetool.prompt` to `false`, so plain `git
///   difftool` and `git mergetool` open Prism.
///
/// Before the first install the global config file's bytes are saved (or
/// the fact that it did not exist). Removing writes those bytes back when
/// the file is still exactly as Prism left it, so comments, indentation
/// and included files survive untouched; a missing file is deleted again.
/// When the file was edited since, removal goes key by key instead: every
/// `difftool.prism.*` and `mergetool.prism.*` key goes, and the default-tool
/// keys get their saved values back if they still hold the value Prism
/// wrote.
public struct GitConfigInstaller: Sendable {
    public enum Mode: String, Sendable, CaseIterable, Codable {
        case defaultTool
        case availableTool
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Every key of the mode has Prism's value.
        case installed
        /// A `prism` command is configured but differs from the current
        /// one (an older Prism, or edited by hand).
        case needsUpdate
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case gitNotFound
        case gitFailed(arguments: [String], message: String)
        case stateFile(String)

        public var description: String {
            switch self {
            case .gitNotFound: "git was not found"
            case .gitFailed(let arguments, let message): "git \(arguments.joined(separator: " ")) failed: \(message)"
            case .stateFile(let message): message
            }
        }
    }

    public static let toolName = PrismInfo.gitToolName
    static let commandKey = "difftool.\(toolName).cmd"
    static let mergeCommandKey = "mergetool.\(toolName).cmd"
    static let trustExitCodeKey = "mergetool.\(toolName).trustExitCode"
    static let defaultToolKeys = ["diff.tool", "difftool.prompt", "merge.tool", "mergetool.prompt"]

    /// The difftool command for a `prism` invoked as `toolCommand`.
    public static func difftoolCommand(tool toolCommand: String) -> String {
        "\(shellQuoted(toolCommand)) --partial-changeset --relative-path \"$MERGED\" -- \"$LOCAL\" \"$REMOTE\""
    }

    /// The mergetool command: git's three files, A and B copied before
    /// `prism` returns, waiting for the merge window (the default). Its exit
    /// status (0 resolved, 1 not) is trusted.
    public static func mergetoolCommand(tool toolCommand: String) -> String {
        "\(shellQuoted(toolCommand)) --merge --output \"$MERGED\" --base \"$BASE\" -- \"$LOCAL\" --snapshot \"$REMOTE\" --snapshot"
    }

    /// `word` as is when it needs no quoting, otherwise in single quotes.
    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+:@%"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The git executable.
    public let git: URL
    /// How `prism` is invoked: `prism`, `prism-diff` or a full path.
    public let toolCommand: String
    /// Environment for git (tests set HOME and GIT_CONFIG_GLOBAL).
    public let environment: [String: String]
    /// Where replaced values are saved.
    public let stateFile: URL

    public init(git: URL, toolCommand: String, environment: [String: String], stateFile: URL) {
        self.git = git
        self.toolCommand = toolCommand
        self.environment = environment
        self.stateFile = stateFile
    }

    /// The first git found in the usual places, then on `PATH`. Apps
    /// started from the Finder get a minimal PATH, so the usual places
    /// come first.
    public static func locateGit(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let usual = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/git" }
        return (usual + fromPath).first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The values each mode sets.
    func values(for mode: Mode) -> [(key: String, value: String)] {
        var values = [(Self.commandKey, Self.difftoolCommand(tool: toolCommand)),
                      (Self.mergeCommandKey, Self.mergetoolCommand(tool: toolCommand)),
                      (Self.trustExitCodeKey, "true")]
        if mode == .defaultTool {
            values += [("diff.tool", Self.toolName), ("difftool.prompt", "false"),
                       ("merge.tool", Self.toolName), ("mergetool.prompt", "false")]
        }
        return values
    }

    // MARK: - Status

    public func status(_ mode: Mode) throws(Failure) -> Status {
        let command = try get(Self.commandKey), mergeCommand = try get(Self.mergeCommandKey)
        guard command != nil || mergeCommand != nil else { return .notInstalled }
        let current = values(for: mode).allSatisfy { key, value in (try? get(key)) == value }
        if current { return .installed }
        // An older Prism (no merge tool yet), or a command edited by hand.
        if command != Self.difftoolCommand(tool: toolCommand)
            || mergeCommand != Self.mergetoolCommand(tool: toolCommand) { return .needsUpdate }
        // The command is right but the default-tool keys are not set.
        return .notInstalled
    }

    // MARK: - Changes

    /// Sets the keys of `mode`, saving the file and the values they replace.
    public func install(_ mode: Mode) throws(Failure) {
        var state = try loadState()
        if state.keys.isEmpty {
            state.originalConfig = Self.read(configFile)
            state.configExisted = FileManager.default.fileExists(atPath: configFile.path)
        }
        for (key, value) in values(for: mode) {
            if state.keys[key] == nil {
                state.keys[key] = SavedValue(previous: try get(key), installed: value)
            } else {
                state.keys[key]?.installed = value
            }
            try saveState(state)
            try run(["config", "--global", "--replace-all", key, value])
        }
        state.installedConfig = Self.read(configFile)
        try saveState(state)
    }

    /// Removes what Prism installed (both modes).
    public func uninstall() throws(Failure) {
        let state = try loadState()
        let current = Self.read(configFile)
        if !state.keys.isEmpty, let installed = state.installedConfig, current == installed {
            try restoreFile(state)
        } else {
            try removeKeyByKey(state)
            if state.configExisted == false, let data = Self.read(configFile),
               data.allSatisfy({ $0 == 0x0A || $0 == 0x20 || $0 == 0x09 }) {
                try? FileManager.default.removeItem(at: configFile)
            }
        }
        try saveState(GitState())
    }

    private func restoreFile(_ state: GitState) throws(Failure) {
        do {
            if state.configExisted == false {
                try FileManager.default.removeItem(at: configFile)
            } else if let original = state.originalConfig {
                try original.write(to: configFile, options: .atomic)
            }
        } catch {
            throw .stateFile("cannot restore \(configFile.path): \((error as NSError).localizedDescription)")
        }
    }

    private func removeKeyByKey(_ state: GitState) throws(Failure) {
        // Every key of the prism tool goes, whatever its value (the tool
        // path may have changed since it was written).
        for (name, keys) in [("difftool", [Self.commandKey]), ("mergetool", [Self.mergeCommandKey, Self.trustExitCodeKey])] {
            let section = try execute(["config", "--global", "--remove-section", "\(name).\(Self.toolName)"])
            for key in keys where section.status != 0 {
                if try get(key) != nil { try run(["config", "--global", "--unset-all", key]) }
            }
        }
        for key in Self.defaultToolKeys {
            guard let saved = state.keys[key] else { continue }
            guard try get(key) == saved.installed else { continue }   // changed by someone else
            if let previous = saved.previous {
                try run(["config", "--global", "--replace-all", key, previous])
            } else {
                try run(["config", "--global", "--unset-all", key])
            }
        }
    }

    /// The file `git config --global` writes: `$GIT_CONFIG_GLOBAL`, else
    /// `~/.gitconfig`, else the XDG `git/config` when only that exists.
    public var configFile: URL {
        if let path = environment["GIT_CONFIG_GLOBAL"], !path.isEmpty {
            return URL(filePath: path)
        }
        let home = environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dotfile = home.appending(path: ".gitconfig")
        if FileManager.default.fileExists(atPath: dotfile.path) { return dotfile }
        let xdgBase = environment["XDG_CONFIG_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        let xdg = xdgBase.appending(path: "git/config")
        return FileManager.default.fileExists(atPath: xdg.path) ? xdg : dotfile
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    // MARK: - git

    /// The global value of `key`, or nil when unset.
    func get(_ key: String) throws(Failure) -> String? {
        let result = try execute(["config", "--global", "--get", key])
        switch result.status {
        case 0: return result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
        case 1: return nil
        default: throw .gitFailed(arguments: ["config", "--global", "--get", key], message: result.error)
        }
    }

    private func run(_ arguments: [String]) throws(Failure) {
        let result = try execute(arguments)
        guard result.status == 0 else { throw .gitFailed(arguments: arguments, message: result.error) }
    }

    private func execute(_ arguments: [String]) throws(Failure) -> (status: Int32, output: String, error: String) {
        guard FileManager.default.isExecutableFile(atPath: git.path) else { throw .gitNotFound }
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw .gitNotFound
        }
        // git config output is small: reading one pipe then the other
        // cannot dead-lock on a full pipe buffer.
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: out, as: UTF8.self),
                String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Saved state

    struct SavedValue: Codable, Equatable {
        /// The value before the first install; nil when the key was unset.
        var previous: String?
        /// The value Prism wrote.
        var installed: String
    }

    struct GitState: Codable, Equatable {
        var keys: [String: SavedValue] = [:]
        /// The config file's bytes before the first install (nil: absent).
        var originalConfig: Data?
        var configExisted: Bool?
        /// The bytes right after the last install.
        var installedConfig: Data?
    }

    /// The saved state; an unreadable file counts as none (removal then
    /// goes key by key, which still removes every `prism` key).
    private func loadState() throws(Failure) -> GitState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(GitState.self, from: data) else { return GitState() }
        return state
    }

    private func saveState(_ state: GitState) throws(Failure) {
        do {
            if state.keys.isEmpty {
                try? FileManager.default.removeItem(at: stateFile)
                return
            }
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(state).write(to: stateFile, options: .atomic)
        } catch {
            throw .stateFile("cannot write \(stateFile.path): \((error as NSError).localizedDescription)")
        }
    }
}
