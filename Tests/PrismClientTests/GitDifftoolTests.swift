// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismIntegration
import PrismProtocol
import PrismTestSupport

// End-to-end runs of real `git difftool` and of the built `prism` binary.
// Every git command runs in a GitSandbox: temporary HOME, temporary
// GIT_CONFIG_GLOBAL, no system config. The socket lives in a temporary
// folder (PRISM_SOCKET_PATH) and PRISM_APP_PATH points nowhere, so the real
// app is never contacted or launched.

private let prismBinary = BuildProducts.executable("prism")
private let stubBinary = BuildProducts.executable("PrismIPCStub")

/// The command Prism's git integration installs.
private func difftoolCommand(_ prism: URL) -> String {
    "'\(prism.path)' --partial-changeset --relative-path \"$MERGED\" -- \"$LOCAL\" \"$REMOTE\""
}

private func configureDifftool(_ sandbox: GitSandbox, prism: URL) throws {
    try sandbox.git(["config", "--global", "difftool.prism.cmd", difftoolCommand(prism)])
}

private func clientProcessesRunning(_ binary: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", binary.path]
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

@Suite(.serialized, .enabled(if: prismBinary != nil, "run `swift build` first: needs .build/*/prism"))
struct GitDifftoolTests {
    @Test func threeModifiedFilesOpenOneChangeset() throws {
        let prism = try #require(prismBinary)
        let harness = try Harness()
        let sandbox = try GitSandbox()
        defer { harness.tearDown(); sandbox.remove() }
        let repository = try sandbox.makeFixtureRepository()
        // make-repo.sh leaves conf.ini and main.swift modified; add a third.
        try "edited in the work tree\n".write(to: repository.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try configureDifftool(sandbox, prism: prism)

        let environment = [IPCEnvironment.socketPathVariable: harness.socketPath,
                           IPCEnvironment.appPathVariable: "/nonexistent/Prism.app"]
        let start = Date()
        let result = try sandbox.git(["difftool", "-y", "-t", "prism"], in: repository, environment: environment)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.status == 0, "\(result.error)")
        #expect(elapsed < 10)

        let documents = harness.sink.documents
        #expect(documents.count == 1)
        let document = try #require(documents.first)
        #expect(document.kind == .partialChangeset)
        #expect(document.title == "Changes in repo")
        #expect(document.tool == .git)
        #expect(document.entries.map(\.relativePath) == ["conf.ini", "main.swift", "notes.txt"])
        #expect(document.entries.allSatisfy { $0.status == .changed })
        // git's blob copies are temporary: the app reads its own copies.
        for entry in document.entries {
            let left = entry.files[0]
            #expect(left.isSnapshot)
            #expect(FileManager.default.fileExists(atPath: left.path))
            #expect(!FileManager.default.fileExists(atPath: left.originalPath), "git removes its copy")
            #expect(entry.files[1].originalPath == repository.appending(path: entry.relativePath).standardizedFileURL.path
                    || entry.files[1].originalPath.hasSuffix("/repo/\(entry.relativePath)"))
        }
        // git has exited, so the changeset is complete.
        #expect(eventually { harness.sink.documents.first?.isComplete == true })
        // Processes git already reaped can linger briefly in the process table.
        #expect(eventually { !clientProcessesRunning(prism) })
    }

    @Test func addedAndDeletedFilesGetTheirStatus() throws {
        let prism = try #require(prismBinary)
        let harness = try Harness()
        let sandbox = try GitSandbox()
        defer { harness.tearDown(); sandbox.remove() }
        let repository = try sandbox.makeFixtureRepository()
        try sandbox.git(["checkout", "--quiet", "--", "."], in: repository)
        try FileManager.default.removeItem(at: repository.appending(path: "notes.txt"))
        try "new\n".write(to: repository.appending(path: "added.txt"), atomically: true, encoding: .utf8)
        try sandbox.git(["add", "-A"], in: repository)
        try configureDifftool(sandbox, prism: prism)
        let result = try sandbox.git(["difftool", "-y", "-t", "prism", "--cached"], in: repository,
                                     environment: [IPCEnvironment.socketPathVariable: harness.socketPath])
        #expect(result.status == 0, "\(result.error)")
        let document = try #require(harness.sink.documents.first)
        #expect(document.title == "\u{201C}--cached\u{201D} in repo")
        let rows = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.relativePath, $0.status) })
        #expect(rows == ["added.txt": .added, "notes.txt": .removed])
    }

    @Test func concurrentRunsStaySeparate() throws {
        let prism = try #require(prismBinary)
        let harness = try Harness()
        let sandbox = try GitSandbox()
        defer { harness.tearDown(); sandbox.remove() }
        let first = try sandbox.makeRepository(named: "first", modifiedFiles: 30)
        let second = try sandbox.makeRepository(named: "second", modifiedFiles: 20)
        try configureDifftool(sandbox, prism: prism)
        let environment = [IPCEnvironment.socketPathVariable: harness.socketPath]
        let runs = [first, second].map { repository in
            Background { (try? sandbox.git(["difftool", "-y", "-t", "prism"], in: repository, environment: environment))?.status ?? -1 }
        }
        #expect(runs.map { $0.result(timeout: 120) } == [0, 0])
        let documents = harness.sink.documents.sorted { $0.entries.count > $1.entries.count }
        #expect(documents.map(\.entries.count) == [30, 20])
        #expect(documents.map(\.title) == ["Changes in first", "Changes in second"])
        #expect(documents[0].entries.map(\.relativePath) == (0..<30).map { String(format: "file%03d.txt", $0) })
    }
}

@Suite(.serialized, .enabled(if: prismBinary != nil && stubBinary != nil,
                             "run `swift build` first: needs .build/*/prism and PrismIPCStub"))
struct ClientWaitProcessTests {
    /// Starts the stub server as its own process, standing in for the app.
    private func startStub(_ socket: String) throws -> Process {
        let process = Process()
        process.executableURL = stubBinary
        process.arguments = ["serve", "--socket", socket]
        process.standardError = FileHandle.nullDevice
        try process.run()
        let client = IPCClient(socketPath: socket)
        guard eventually(timeout: 10, { client.isServerRunning(timeout: 1) }) else {
            process.terminate()
            throw GitSandbox.SandboxError(message: "stub server did not start")
        }
        return process
    }

    private func startClient(_ socket: String, _ args: [String]) throws -> Process {
        let process = Process()
        process.executableURL = prismBinary
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment[IPCEnvironment.socketPathVariable] = socket
        environment[IPCEnvironment.appPathVariable] = "/nonexistent/Prism.app"
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func documentCount(_ socket: String) -> Int {
        (try? IPCClient(socketPath: socket).send(Request(operation: .status)).0.documents?.count) ?? -1
    }

    @Test func waitEndsWhenTheDocumentCloses() throws {
        let folder = try shortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "s.sock").path
        let a = Corpus.fixture("text/a.swift").path
        let b = Corpus.fixture("text/b.swift").path
        let stub = try startStub(socket)
        defer { stub.terminate(); stub.waitUntilExit() }
        let prism = try startClient(socket, ["--wait", a, b])
        #expect(eventually { documentCount(socket) == 1 })
        usleep(200_000)
        #expect(prism.isRunning)
        kill(stub.processIdentifier, SIGUSR1)      // "close every window"
        prism.waitUntilExit()
        #expect(prism.terminationStatus == 0)
    }

    @Test func killingTheAppEndsTheWaitWithinATenthOfASecond() throws {
        let folder = try shortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "s.sock").path
        let stub = try startStub(socket)
        let prism = try startClient(socket, ["-w", Corpus.fixture("text/a.swift").path, Corpus.fixture("text/b.swift").path])
        #expect(eventually { documentCount(socket) == 1 })
        usleep(100_000)
        let killed = Date()
        kill(stub.processIdentifier, SIGKILL)
        prism.waitUntilExit()
        let latency = Date().timeIntervalSince(killed)
        stub.waitUntilExit()
        #expect(prism.terminationStatus == 1)
        #expect(latency < 0.1, "prism took \(latency) s to notice")
    }
}
