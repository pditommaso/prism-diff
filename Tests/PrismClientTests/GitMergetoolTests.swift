// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismIntegration
import PrismProtocol
import PrismTestSupport

// End-to-end runs of real `git mergetool` with the built `prism` and the
// stub server (PrismIPCStub) standing in for the app: the stub merges the
// files headlessly with DiffCore, gives every conflict the choice it was
// started with, saves the result and reports the merge resolved; with no
// choice it reports it unresolved. Everything runs in a GitSandbox
// (temporary HOME and GIT_CONFIG_GLOBAL); PRISM_APP_PATH points nowhere,
// so the real app is never launched.

private let prismBinary = BuildProducts.executable("prism")
private let stubBinary = BuildProducts.executable("PrismIPCStub")

extension GitSandbox {
    /// A repository where merging branch `feature` into `master` leaves
    /// `notes.txt` conflicted: line 2 differs on both sides.
    func makeConflictedRepository(named name: String = "conflict") throws -> URL {
        let repository = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let notes = repository.appending(path: "notes.txt")
        func commit(_ text: String, _ message: String) throws {
            try text.write(to: notes, atomically: true, encoding: .utf8)
            try git(["commit", "--quiet", "-am", message], in: repository)
        }
        try git(["init", "--quiet", "--initial-branch=master", "--template="], in: repository)
        try "line1\nline2\nline3\n".write(to: notes, atomically: true, encoding: .utf8)
        try git(["add", "notes.txt"], in: repository)
        try git(["commit", "--quiet", "-m", "init"], in: repository)
        try git(["checkout", "--quiet", "-b", "feature"], in: repository)
        try commit("line1\nline2 feature\nline3\n", "feature")
        try git(["checkout", "--quiet", "master"], in: repository)
        try commit("line1\nline2 main\nline3\n", "main")
        let merge = try git(["merge", "--quiet", "feature"], in: repository)
        guard merge.status != 0 else { throw SandboxError(message: "the merge did not conflict") }
        return repository
    }
}

@Suite(.serialized, .enabled(if: prismBinary != nil && stubBinary != nil,
                             "run `swift build` first: needs .build/*/prism and PrismIPCStub"))
struct GitMergetoolTests {
    /// Starts the stub server; it closes each merge 300 ms after it opens.
    private func startStub(_ socket: String, choice: String) throws -> Process {
        let process = Process()
        process.executableURL = stubBinary
        process.arguments = ["serve", "--socket", socket, "--close-after-ms", "300", "--merge-choice", choice]
        process.standardError = FileHandle.nullDevice
        try process.run()
        let client = IPCClient(socketPath: socket)
        guard eventually(timeout: 10, { client.isServerRunning(timeout: 1) }) else {
            process.terminate()
            throw GitSandbox.SandboxError(message: "stub server did not start")
        }
        return process
    }

    /// Installs Prism's git integration (as the Integration window does)
    /// with the built prism, then runs `git mergetool -y -t prism`.
    private func runMergetool(choice: String) throws -> (result: GitSandbox.Result, repository: URL,
                                                         sandbox: GitSandbox, status: String) {
        let prism = try #require(prismBinary)
        let sandbox = try GitSandbox()
        let folder = try shortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "s.sock").path
        let stub = try startStub(socket, choice: choice)
        defer { stub.terminate(); stub.waitUntilExit() }
        let installer = GitConfigInstaller(git: URL(fileURLWithPath: "/usr/bin/git"), toolCommand: prism.path,
                                           environment: sandbox.environment(),
                                           stateFile: sandbox.root.appending(path: "state.json"))
        try installer.install(.availableTool)
        let repository = try sandbox.makeConflictedRepository()
        let result = try sandbox.git(["mergetool", "-y", "-t", "prism"], in: repository,
                                     environment: [IPCEnvironment.socketPathVariable: socket])
        let status = try sandbox.git(["status", "--porcelain"], in: repository).output
        return (result, repository, sandbox, status)
    }

    @Test func resolvedMergeExitsZeroAndGitMarksTheFileResolved() throws {
        let run = try runMergetool(choice: "a")
        defer { run.sandbox.remove() }
        #expect(run.result.status == 0, "\(run.result.output) \(run.result.error)")
        let text = try String(contentsOf: run.repository.appending(path: "notes.txt"), encoding: .utf8)
        #expect(text == "line1\nline2 main\nline3\n")
        // Resolved and staged: A is master's own version, so nothing is left
        // to commit for notes.txt, and nothing is unmerged.
        #expect(!run.status.contains("UU"), "\(run.status)")
        #expect(!run.status.split(separator: "\n").contains { $0.hasSuffix(" notes.txt") }, "\(run.status)")
    }

    @Test func unresolvedMergeExitsOneAndTheFileStaysConflicted() throws {
        let run = try runMergetool(choice: "none")
        defer { run.sandbox.remove() }
        #expect(run.result.status != 0)
        #expect((run.result.output + run.result.error).contains("merge of notes.txt failed"))
        #expect(run.status.contains("UU notes.txt"), "\(run.status)")
        let text = try String(contentsOf: run.repository.appending(path: "notes.txt"), encoding: .utf8)
        #expect(text.contains("<<<<<<<"), "git keeps its conflict markers")
    }

    @Test func mergeExitStatusFollowsTheResolution() throws {
        let prism = try #require(prismBinary)
        for (choice, expected) in [("b", Int32(0)), ("none", Int32(1))] {
            let folder = try shortSocketDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let socket = folder.appending(path: "s.sock").path
            let stub = try startStub(socket, choice: choice)
            defer { stub.terminate(); stub.waitUntilExit() }
            let merge = Corpus.directory.appending(path: "merge/notes", directoryHint: .isDirectory)
            let output = folder.appending(path: "out.txt")      // missing: only a save creates it
            let process = Process()
            process.executableURL = prism
            process.arguments = ["--merge", "--output", output.path, "--base", merge.appending(path: "base.txt").path,
                                 "--", merge.appending(path: "a.txt").path, merge.appending(path: "b.txt").path]
            var environment = ProcessInfo.processInfo.environment
            environment[IPCEnvironment.socketPathVariable] = socket
            environment[IPCEnvironment.appPathVariable] = "/nonexistent/Prism.app"
            process.environment = environment
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == expected, "choice \(choice)")
            if expected == 0 {
                #expect(try String(contentsOf: output, encoding: .utf8) == "line1\nline2 feature\nline3\n")
            } else {
                #expect(!FileManager.default.fileExists(atPath: output.path), "nothing saved, nothing created")
            }
        }
    }
}

/// `prism --merge` against the in-process server: what the app receives,
/// and the exit status for each way the merge window can close.
@Suite(.serialized) struct ClientMergeTests {
    private func merge(resolved: Bool?) throws -> (status: Int32, document: DocumentContent?, output: URL, stderr: String) {
        let harness = try Harness()
        defer { harness.tearDown() }
        let source = Corpus.directory.appending(path: "merge/notes", directoryHint: .isDirectory)
        let output = harness.folder.appending(path: "result.txt")
        let args = ["--merge", "--output", output.path, "--base", source.appending(path: "base.txt").path,
                    source.appending(path: "a.txt").path, source.appending(path: "b.txt").path]
        let run = Background { harness.prism(args) }
        _ = eventually { !harness.sink.documents.isEmpty }
        let document = harness.sink.documents.first
        if let document {
            switch resolved {
            case .some(let value): harness.router.mergeFinished(document.id, resolved: value)
            case .none: harness.router.documentClosed(document.id)
            }
        }
        let outcome = run.result(timeout: 10)
        return (outcome?.status ?? -1, document, output, outcome?.stderr ?? "")
    }

    @Test func theAppGetsAMergeDocument() throws {
        let run = try merge(resolved: true)
        let document = try #require(run.document)
        #expect(document.kind == .merge)
        #expect(document.title == "result.txt")
        #expect(document.mergeOutput == run.output.standardizedFileURL.path
                || document.mergeOutput?.hasSuffix("/result.txt") == true)
        let files = try #require(document.entries.first?.files)
        #expect(files.map(\.fileName) == ["a.txt", "b.txt", "base.txt"])
    }

    @Test(arguments: [(Optional(true), Int32(0)), (Optional(false), Int32(1)), (nil, Int32(1))])
    func exitStatusFollowsTheOutcome(resolved: Bool?, status: Int32) throws {
        let run = try merge(resolved: resolved)
        #expect(run.status == status, "\(run.stderr)")
    }

    @Test func theOutputIsNotCreatedBeforeTheAppAcceptsTheMerge() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let source = Corpus.directory.appending(path: "merge/notes", directoryHint: .isDirectory)
        let output = harness.folder.appending(path: "later.txt")
        let run = Background { harness.prism(["--merge", "--output", output.path,
                                               source.appending(path: "a.txt").path, source.appending(path: "b.txt").path]) }
        #expect(eventually { !harness.sink.documents.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: output.path))
        if let id = harness.sink.documents.first?.id { harness.router.documentClosed(id) }
        #expect(run.result(timeout: 10)?.status == 1)
        // An output in a folder that does not exist is a usage error.
        let missing = harness.prism(["--merge", "--output", "/nonexistent/folder/out.txt",
                                      source.appending(path: "a.txt").path, source.appending(path: "b.txt").path])
        #expect(missing.status == 1 && missing.stderr.contains("no such folder"))
    }

    @Test func missingFilesAreRefused() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let outcome = harness.prism(["--merge", "--output", harness.folder.appending(path: "o").path,
                                      "/nonexistent/a", "/nonexistent/b"])
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("no such file"))
        #expect(!FileManager.default.fileExists(atPath: harness.folder.appending(path: "o").path))
    }
}
