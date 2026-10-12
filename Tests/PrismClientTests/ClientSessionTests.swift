// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismIntegration
import PrismProtocol
import PrismTestSupport
@testable import PrismClient

/// A short directory for sockets: temporary paths can exceed sun_path.
func shortSocketDirectory() throws -> URL {
    var template = Array("/tmp/prism-t.XXXXXX".utf8CString)
    guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
    return URL(fileURLWithPath: String(cString: made), isDirectory: true)
}

/// An in-process server plus a prism context pointing at it.
final class Harness: @unchecked Sendable {
    let folder: URL
    let socketPath: String
    let sink = RecordingSink()
    let router: ChangesetRouter
    private(set) var server: IPCServer?
    let caller: CallerInfo

    init(start: Bool = true, authorize: @escaping @Sendable (uid_t) -> Bool = { $0 == getuid() }) throws {
        folder = try shortSocketDirectory()
        socketPath = folder.appending(path: "s.sock").path
        router = ChangesetRouter(sink: sink, snapshots: SnapshotStore(root: folder.appending(path: "snap")))
        caller = CallerInfo(process: nil, name: "zsh", arguments: [], tool: .unknown, workingDirectory: folder.path)
        self.authorize = authorize
        if start { try startServer() }
    }

    private let authorize: @Sendable (uid_t) -> Bool

    func startServer() throws {
        let server = IPCServer(socketPath: socketPath, router: router, authorize: authorize)
        try server.start()
        self.server = server
    }

    func tearDown() {
        server?.stop()
        router.shutdown()
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ name: String, _ text: String = "x\n") throws -> String {
        let url = folder.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func context(launcher: AppLauncher? = nil, launchTimeout: Double = 2) -> ClientContext {
        let caller = self.caller
        return ClientContext(
            environment: [IPCEnvironment.socketPathVariable: socketPath],
            workingDirectory: folder.path,
            caller: { caller },
            launcher: launcher ?? AppLauncher { throw AppLauncher.LaunchError(message: "no app in tests") },
            launchTimeout: launchTimeout
        )
    }

    struct Outcome {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    func prism(_ args: [String], launcher: AppLauncher? = nil, launchTimeout: Double = 2) -> Outcome {
        let out = CapturedOutput()
        let err = CapturedOutput()
        let status = ClientCommand.run(args, stdout: out.sink, stderr: err.sink,
                                       context: context(launcher: launcher, launchTimeout: launchTimeout))
        return Outcome(status: status, stdout: out.text, stderr: err.text)
    }
}

/// Runs `body` on a background thread; `result()` blocks until it is done.
final class Background<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    init(_ body: @escaping @Sendable () -> T) {
        Thread { [self] in
            let result = body()
            lock.withLock { value = result }
        }.start()
    }

    func result(timeout: Double = 10) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = lock.withLock({ value }) { return value }
            usleep(1_000)
        }
        return lock.withLock { value }
    }

    var isFinished: Bool { lock.withLock { value != nil } }
}

@Suite(.serialized) struct ClientSessionTests {
    @Test func diffOpensADocumentAndReturnsAtOnce() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let a = try harness.file("a.txt")
        let b = try harness.file("b.txt")
        let outcome = harness.prism(["a.txt", "b.txt"])
        #expect(outcome.status == 0, "\(outcome.stderr)")
        #expect(outcome.stdout.isEmpty && outcome.stderr.isEmpty)
        let documents = harness.sink.documents
        #expect(documents.count == 1)
        #expect(documents.first?.kind == .diff)
        #expect(documents.first?.entries.first?.files.map(\.originalPath) == [a, b])
    }

    @Test func partialChangesetsShareADocument() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        for name in ["one", "two", "three"] {
            _ = try harness.file(name)
            let outcome = harness.prism(["--partial-changeset", "--UUID", "U", "--relative-path", name, "--", "/dev/null", name])
            #expect(outcome.status == 0, "\(outcome.stderr)")
        }
        #expect(harness.sink.documents.count == 1)
        #expect(harness.sink.documents[0].entries.map(\.relativePath) == ["one", "two", "three"])
        #expect(harness.sink.documents[0].entries.map(\.status) == [.added, .added, .added])
        #expect(harness.prism(["--mark-changeset-as-closed", "U"]).status == 0)
        harness.router.drain()
        #expect(harness.sink.documents[0].isComplete)
    }

    @Test func waitBlocksUntilTheDocumentCloses() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        _ = try harness.file("a")
        _ = try harness.file("b")
        let run = Background { harness.prism(["--wait", "a", "b"]) }
        #expect(eventually { harness.sink.documents.count == 1 })
        usleep(200_000)
        #expect(!run.isFinished)
        harness.router.documentClosed(harness.sink.documents[0].id)
        let outcome = try #require(run.result())
        #expect(outcome.status == 0, "\(outcome.stderr)")
    }

    @Test func waitFailsWhenTheAppGoesAway() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        _ = try harness.file("a")
        _ = try harness.file("b")
        let run = Background { harness.prism(["-w", "a", "b"]) }
        #expect(eventually { harness.sink.documents.count == 1 })
        let start = Date()
        harness.server?.stop()
        let outcome = try #require(run.result())
        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("quit before the comparison was closed"))
    }

    @Test func appIsLaunchedWhenNotRunning() throws {
        let harness = try Harness(start: false)
        defer { harness.tearDown() }
        _ = try harness.file("a")
        _ = try harness.file("b")
        let launches = Counter()
        let launcher = AppLauncher {
            launches.increment()
            // The app needs a moment before it listens.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { try? harness.startServer() }
        }
        let outcome = harness.prism(["a", "b"], launcher: launcher)
        #expect(outcome.status == 0, "\(outcome.stderr)")
        #expect(launches.value == 1)
        #expect(harness.sink.documents.count == 1)
    }

    @Test func launchTimeoutIsAnError() throws {
        let harness = try Harness(start: false)
        defer { harness.tearDown() }
        _ = try harness.file("a")
        _ = try harness.file("b")
        let outcome = harness.prism(["a", "b"], launcher: AppLauncher {}, launchTimeout: 0.3)
        #expect(outcome.status == 1)
        #expect(outcome.stderr.contains("did not start within"))
        let failing = harness.prism(["a", "b"])
        #expect(failing.status == 1)
        #expect(failing.stderr.contains("cannot launch Prism"))
    }

    @Test func refusedConnectionIsACommunicationError() throws {
        let harness = try Harness(authorize: { _ in false })
        defer { harness.tearDown() }
        _ = try harness.file("a")
        _ = try harness.file("b")
        let outcome = harness.prism(["a", "b"])
        #expect(outcome.status == 255)
        #expect(outcome.stderr.hasPrefix("prism: cannot communicate with Prism"))
    }

    @Test func refusedRequestExitsOne() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        // A file to snapshot that the app cannot read.
        let locked = try harness.file("locked.txt")
        _ = try harness.file("b.txt")
        chmod(locked, 0)
        defer { chmod(locked, 0o644) }
        let outcome = harness.prism(["--", "locked.txt", "--snapshot", "b.txt"])
        #expect(outcome.status == 1)
        #expect(outcome.stderr.hasPrefix("prism: cannot copy \(locked)"))
        #expect(harness.sink.documents.isEmpty)
    }

    @Test func markClosedWithoutAppSucceeds() throws {
        let harness = try Harness(start: false)
        defer { harness.tearDown() }
        #expect(harness.prism(["--mark-changeset-as-closed", "X"]).status == 0)
    }

    @Test func supportsCapability() throws {
        let harness = try Harness(start: false)
        defer { harness.tearDown() }
        #expect(harness.prism(["--supports-capability", "diffs-v1"]).stdout == "YES\n")
        #expect(harness.prism(["--supports-capability", "merges-v1"]).stdout == "YES\n")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

func eventually(timeout: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

@Test func launchForwardsPrismVariablesOnly() {
    let forwarded = AppLauncher.forwardedEnvironment([
        "PRISM_SOCKET_PATH": "/tmp/s.sock", "PRISM_PERF_LOG": "/tmp/p.log", "PRISM_APP_PATH": "/A.app",
        "PRISM_LAUNCHED_BY_CLI": "1", "PRISM_EMPTY": "", "HOME": "/Users/me",
        "PRISM_TESTING": "1", "PRISM_HELPERS_DIR": "/evil", "PRISM_DEBUG_DIFF_DELAY_MS": "9",
    ])
    #expect(forwarded.map(\.0) == ["PRISM_PERF_LOG", "PRISM_SOCKET_PATH", "PRISM_TESTING"])
}
