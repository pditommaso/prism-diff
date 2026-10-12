// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismProtocol
import PrismTestSupport
@testable import PrismIntegration

/// A short directory for sockets: temporary paths can exceed sun_path.
func shortSocketDirectory() throws -> URL {
    var template = Array("/tmp/prism-t.XXXXXX".utf8CString)
    guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
    return URL(fileURLWithPath: String(cString: made), isDirectory: true)
}

/// A running server with a recording sink, in a private folder.
final class ServerFixture: @unchecked Sendable {
    let folder: URL
    let sink = RecordingSink()
    let router: ChangesetRouter
    let server: IPCServer
    let snapshots: SnapshotStore

    init(
        idleTimeout: TimeInterval = 10,
        sweepInterval: TimeInterval = 2,
        authorize: @escaping @Sendable (uid_t) -> Bool = { $0 == getuid() }
    ) throws {
        folder = try shortSocketDirectory()
        snapshots = SnapshotStore(root: folder.appending(path: "snap"))
        router = ChangesetRouter(sink: sink, snapshots: snapshots, idleTimeout: idleTimeout, sweepInterval: sweepInterval, snapshotGrace: 0)
        server = IPCServer(socketPath: folder.appending(path: "s.sock").path, router: router, authorize: authorize)
        try server.start()
    }

    var client: IPCClient { IPCClient(socketPath: server.socketPath) }

    func tearDown() {
        server.stop()
        router.shutdown()
        try? FileManager.default.removeItem(at: folder)
    }

    func open(_ invocation: Invocation) throws -> Reply {
        try client.send(Request(operation: .open, invocation: invocation)).0
    }
}

func caller(pid: Int32 = 4242, start: Int64 = 1, uuidCwd: String = "/w/repo", tool: VersionControlTool = .git) -> CallerInfo {
    CallerInfo(
        process: ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0),
        name: "git", arguments: ["git", "diff"], tool: tool, workingDirectory: uuidCwd
    )
}

func pair(_ a: String, _ b: String, relative: String? = nil, status: FileStatus = .changed,
          temporary: Bool = false) -> FileList {
    FileList(files: [FileReference(path: a, temporary: temporary), FileReference(path: b, temporary: false)],
             status: status, relativePath: relative)
}

/// Polls `condition` for up to `timeout` seconds.
func eventually(timeout: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

@Suite(.serialized) struct ServerTests {
    @Test func answersPingAndStatus() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let (reply, _) = try fixture.client.send(Request(operation: .ping))
        #expect(reply.ok)
        #expect(reply.serverPID == getpid())
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.server.socketPath)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let (status, _) = try fixture.client.send(Request(operation: .status))
        #expect(status.documents == [])
    }

    @Test func refusesAnotherUser() throws {
        // Simulated: the server believes every peer is someone else.
        let fixture = try ServerFixture(authorize: { $0 != getuid() })
        defer { fixture.tearDown() }
        let invocation = Invocation(kind: .diff, fileLists: [pair("/a", "/b")], caller: caller())
        do {
            _ = try fixture.client.send(Request(operation: .open, invocation: invocation))
            Issue.record("the request was answered")
        } catch {
            guard case .transport = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(fixture.sink.documents.isEmpty)
    }

    @Test func peerUIDCheckSeesTheRealUser() throws {
        let seen = UIDBox()
        let fixture = try ServerFixture(authorize: { uid in seen.set(uid); return true })
        defer { fixture.tearDown() }
        _ = try fixture.client.send(Request(operation: .ping))
        #expect(seen.value == getuid())
    }

    @Test func secondServerOnTheSamePathIsRefused() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let other = IPCServer(socketPath: fixture.server.socketPath, router: fixture.router)
        #expect(throws: IPCServer.StartError.self) { try other.start() }
        // The first server is unaffected.
        #expect(fixture.client.isServerRunning())
    }

    @Test func staleSocketFileIsReplaced() throws {
        let folder = try shortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "s.sock").path
        let stale = try UnixSocket.listen(at: path)
        close(stale)        // the file stays, nobody listens
        let router = ChangesetRouter(sink: RecordingSink(), snapshots: nil)
        let server = IPCServer(socketPath: path, router: router)
        try server.start()
        #expect(IPCClient(socketPath: path).isServerRunning())
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func rejectsAnotherProtocolVersion() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let (reply, _) = try fixture.client.send(Request(operation: .ping, protocolVersion: 99))
        #expect(!reply.ok)
        #expect(reply.error?.contains("version 99") == true)
    }

    @Test func rejectsGarbage() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let fd = try UnixSocket.connect(to: fixture.server.socketPath)
        defer { close(fd) }
        try Framing.write(Data("not json".utf8), to: fd)
        let reply = try WireCoding.decode(Reply.self, from: Framing.read(from: fd))
        #expect(!reply.ok)
    }

    @Test func waitingClientIsWokenWhenTheDocumentCloses() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let invocation = Invocation(kind: .diff, fileLists: [pair("/a", "/b")], wait: true, caller: caller())
        let (reply, connection) = try fixture.client.send(Request(operation: .open, invocation: invocation), keepOpen: true)
        let id = try #require(reply.documentID)
        let waiting = try #require(connection)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { fixture.router.documentClosed(id) }
        let event = try waiting.waitForEvent()
        #expect(event == Event(kind: .documentClosed, documentID: id))
        #expect(fixture.router.status().first?.isClosed == true)
    }

    @Test func waitingClientSeesTheServerStop() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let invocation = Invocation(kind: .diff, fileLists: [pair("/a", "/b")], wait: true, caller: caller())
        let (_, connection) = try fixture.client.send(Request(operation: .open, invocation: invocation), keepOpen: true)
        let waiting = try #require(connection)
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { fixture.server.stop() }
        #expect(throws: Framing.Error.closed) { try waiting.waitForEvent() }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func departedWaiterIsDropped() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let invocation = Invocation(kind: .diff, fileLists: [pair("/a", "/b")], wait: true, caller: caller())
        let (reply, connection) = try fixture.client.send(Request(operation: .open, invocation: invocation), keepOpen: true)
        connection?.close()
        usleep(100_000)
        // Closing the document now writes to nobody and must not crash.
        fixture.router.documentClosed(try #require(reply.documentID))
        fixture.router.drain()
        #expect(fixture.client.isServerRunning())
    }

    @Test func temporaryFilesAreCopiedBeforeTheReply() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let source = fixture.folder.appending(path: "blob.txt")
        try "old\n".write(to: source, atomically: true, encoding: .utf8)
        let reply = try fixture.open(Invocation(
            kind: .partialChangeset,
            fileLists: [pair(source.path, "/w/repo/blob.txt", relative: "blob.txt", temporary: true)],
            caller: caller()))
        // The caller may delete its file as soon as it has the reply.
        try FileManager.default.removeItem(at: source)
        let id = try #require(reply.documentID)
        let document = try #require(fixture.sink.document(id))
        let left = document.entries[0].files[0]
        #expect(left.isSnapshot)
        #expect(left.originalPath == source.path)
        #expect(left.fileName == "blob.txt")
        #expect((left.path as NSString).lastPathComponent == "blob.txt")
        #expect(try String(contentsOfFile: left.path, encoding: .utf8) == "old\n")
        #expect(!document.entries[0].files[1].isSnapshot)

        fixture.router.documentClosed(document.id)
        #expect(eventually { !FileManager.default.fileExists(atPath: left.path) })
    }

    @Test func foldersAreNeverSnapshotted() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let tree = fixture.folder.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "a/b"), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: tree.appending(path: "a/b/big"))
        let reply = try fixture.open(Invocation(kind: .diff, fileLists: [FileList(files: [
            FileReference(path: tree.path, temporary: true), FileReference(path: tree.path + "/a", temporary: true)])],
            caller: caller()))
        #expect(reply.ok)
        let copied = FileManager.default.enumerator(atPath: fixture.snapshots.root.path)?.allObjects ?? []
        #expect(copied.isEmpty)
        let files = try #require(fixture.sink.documents.first?.entries.first?.files)
        #expect(files.allSatisfy { !$0.isSnapshot })
    }

    @Test func missingTemporaryFileFailsTheRequest() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let reply = try fixture.open(Invocation(
            kind: .diff, fileLists: [pair("/tmp/does-not-exist-\(UUID())", "/b", temporary: true)], caller: caller()))
        #expect(!reply.ok)
        #expect(reply.error?.hasPrefix("cannot copy") == true)
        #expect(fixture.sink.documents.isEmpty)
    }
}

final class UIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: uid_t?
    func set(_ uid: uid_t) { lock.withLock { stored = uid } }
    var value: uid_t? { lock.withLock { stored } }
}

// Regression tests from the M5 check: slow or idle clients.
@Suite(.serialized) struct ServerRobustnessTests {
    @Test func idleConnectionsDoNotBlockOthers() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        var idle: [Int32] = []
        for _ in 0..<150 {
            if let fd = try? UnixSocket.connect(to: fixture.server.socketPath) { idle.append(fd) }
        }
        defer { idle.forEach { close($0) } }
        Thread.sleep(forTimeInterval: 0.3)
        let start = Date()
        #expect(fixture.client.isServerRunning(timeout: 5))
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func aTricklingClientIsCutOffAtTheDeadline() throws {
        let folder = try shortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let router = ChangesetRouter(sink: RecordingSink(), snapshots: nil)
        let server = IPCServer(socketPath: folder.appending(path: "s.sock").path, router: router, requestTimeout: 1)
        try server.start()
        defer { server.stop(); router.shutdown() }
        let fd = try UnixSocket.connect(to: server.socketPath)
        defer { close(fd) }
        var header: [UInt8] = [0, 0, 0, 16]
        _ = write(fd, &header, 4)
        // One byte every 0.4 s: each read is quick, but the whole request
        // never completes.
        var closedByServer = false
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.4)
            var byte: UInt8 = 0x20
            if write(fd, &byte, 1) != 1 { closedByServer = true; break }
            var peek: UInt8 = 0
            if recv(fd, &peek, 1, MSG_DONTWAIT | MSG_PEEK) == 0 { closedByServer = true; break }
        }
        #expect(closedByServer)
    }

    @Test func hugeAnnouncedFramesAreNotPreallocated() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        for _ in 0..<20 {
            let fd = try UnixSocket.connect(to: fixture.server.socketPath)
            var header: [UInt8] = [0x04, 0x00, 0x00, 0x00]   // 64 MiB announced
            _ = write(fd, &header, 4)
            fds.append(fd)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(fixture.client.isServerRunning(timeout: 5))
    }

    @Test func oversizedHeaderIsRejected() throws {
        let fixture = try ServerFixture()
        defer { fixture.tearDown() }
        let fd = try UnixSocket.connect(to: fixture.server.socketPath)
        defer { close(fd) }
        var header: [UInt8] = [0x7F, 0xFF, 0xFF, 0xFF]
        _ = write(fd, &header, 4)
        #expect(throws: Framing.Error.closed) { try Framing.read(from: fd) }
    }

    @Test func existingSocketFolderIsMadePrivate() throws {
        let folder = try shortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sub = folder.appending(path: "Prism")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let router = ChangesetRouter(sink: RecordingSink(), snapshots: nil)
        let server = IPCServer(socketPath: sub.appending(path: "s.sock").path, router: router, securesDirectory: true)
        try server.start()
        defer { server.stop(); router.shutdown() }
        let mode = try FileManager.default.attributesOfItem(atPath: sub.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}

@Test func staleSnapshotFoldersOfDeadProcessesAreRemoved() throws {
    let parent = try TemporaryDirectory(prefix: "prism-stale")
    defer { parent.remove() }
    let fm = FileManager.default
    // A PID that is not running, our own PID, and an unrelated folder.
    var dead: Int32 = 999_990
    while kill(dead, 0) == 0 || errno != ESRCH { dead -= 1 }
    let stale = parent.url.appending(path: "\(SnapshotStore.folderPrefix)\(dead)")
    let mine = SnapshotStore.temporary(in: parent.url).root
    let other = parent.url.appending(path: "unrelated")
    for folder in [stale, mine, other] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    let removed = SnapshotStore.removeStale(in: parent.url)
    #expect(removed.map(\.lastPathComponent) == [stale.lastPathComponent])
    #expect(!fm.fileExists(atPath: stale.path))
    #expect(fm.fileExists(atPath: mine.path) && fm.fileExists(atPath: other.path))
}
