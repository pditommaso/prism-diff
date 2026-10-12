// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Built executables of this package, for tests that must run a real
/// binary (for example as git's diff tool). `swift test` does not link
/// executables, but `swift build` and `scripts/ci/build-strict.sh` do; tests
/// that need one are skipped when it is missing.
public enum BuildProducts {
    /// `.build/debug/<name>` or `.build/release/<name>`, the newer of the two,
    /// or nil when neither exists.
    public static func executable(_ name: String) -> URL? {
        let fileManager = FileManager.default
        let candidates = ["debug", "release"].map {
            Corpus.root.appending(path: ".build/\($0)/\(name)", directoryHint: .notDirectory)
        }.filter { fileManager.isExecutableFile(atPath: $0.path) }
        return candidates.max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// A git environment isolated from the user's: a temporary HOME, an empty
/// global config file (GIT_CONFIG_GLOBAL) and no system config. Nothing in
/// the user's real configuration is read or written.
public struct GitSandbox: Sendable {
    public let root: URL
    public let home: URL
    public let globalConfig: URL

    public init() throws {
        let directory = try TemporaryDirectory(prefix: "prism-git")
        root = directory.url
        home = root.appending(path: "home", directoryHint: .isDirectory)
        globalConfig = root.appending(path: "gitconfig", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: globalConfig.path, contents: Data())
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The environment for git and the tools it runs: the current one with
    /// HOME and the git config redirected, plus `extra`.
    public func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appending(path: ".config").path
        environment["GIT_CONFIG_GLOBAL"] = globalConfig.path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "t"
        environment["GIT_AUTHOR_EMAIL"] = "t@t"
        environment["GIT_COMMITTER_NAME"] = "t"
        environment["GIT_COMMITTER_EMAIL"] = "t@t"
        // A prism run from here must never start a real Prism.app: with
        // an unreachable socket it would otherwise launch the registered
        // app (open -b). Tests that want a socket pass PRISM_SOCKET_PATH.
        for key in environment.keys where key.hasPrefix("PRISM_") {
            environment.removeValue(forKey: key)
        }
        environment["PRISM_APP_PATH"] = "/nonexistent/Prism.app"
        environment["PRISM_SOCKET_PATH"] = root.appending(path: "no-app.sock").path
        environment["PRISM_TESTING"] = "1"
        environment.merge(extra) { $1 }
        return environment
    }

    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let error: String
    }

    /// Runs a program with the sandbox environment and waits for it.
    @discardableResult
    public func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment extra: [String: String] = [:]
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(extra)
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read both pipes concurrently so that neither can fill up and block.
        let errorData = LockedData()
        let reader = Thread { errorData.set(error.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while !errorData.isSet { usleep(1_000) }
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData.value, as: UTF8.self)
        )
    }

    /// Runs git.
    @discardableResult
    public func git(_ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:]) throws -> Result {
        try run("/usr/bin/git", arguments, in: directory, environment: environment)
    }

    /// Builds the corpus fixture repository (Tests/corpus/scripts/make-repo.sh)
    /// at `<root>/<name>`: master checked out, 2 modified files.
    public func makeFixtureRepository(named name: String = "repo") throws -> URL {
        let repository = root.appending(path: name, directoryHint: .isDirectory)
        let script = Corpus.directory.appending(path: "scripts/make-repo.sh").path
        let result = try run("/bin/bash", [script, repository.path])
        guard result.status == 0 else {
            throw SandboxError(message: "make-repo.sh failed: \(result.error)")
        }
        return repository
    }

    /// A repository with `count` committed files, each then modified in the
    /// work tree (`file000.txt`, ...).
    public func makeRepository(named name: String, modifiedFiles count: Int) throws -> URL {
        let repository = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--initial-branch=master", "--template="], in: repository)
        let names = (0..<count).map { String(format: "file%03d.txt", $0) }
        for name in names {
            try "line 1\nline 2\n".write(to: repository.appending(path: name), atomically: true, encoding: .utf8)
        }
        try git(["add", "-A"], in: repository)
        let commit = try git(["-c", "commit.gpgSign=false", "commit", "--quiet", "--no-verify", "-m", "init"], in: repository)
        guard commit.status == 0 else { throw SandboxError(message: "commit failed: \(commit.error)") }
        for name in names {
            try "line 1\nline 2 changed\n".write(to: repository.appending(path: name), atomically: true, encoding: .utf8)
        }
        return repository
    }

    public struct SandboxError: Error, CustomStringConvertible {
        public let message: String
        public init(message: String) { self.message = message }
        public var description: String { message }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ value: Data) { lock.withLock { data = value } }
    var isSet: Bool { lock.withLock { data != nil } }
    var value: Data { lock.withLock { data ?? Data() } }
}
