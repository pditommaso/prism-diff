// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismTestSupport
@testable import PrismProtocol

private let caller = CallerInfo(
    process: ProcessIdentity(pid: 42, startSeconds: 1_700_000_000, startMicroseconds: 123),
    name: "git",
    arguments: ["git", "diff"],
    tool: .git,
    workingDirectory: "/work/repo"
)

@Test func requestRoundTripsThroughJSON() throws {
    let invocation = Invocation(
        kind: .partialChangeset,
        fileLists: [FileList(
            files: [FileReference(path: "/tmp/x/a.txt", temporary: true), FileReference(path: "/work/repo/a.txt", temporary: false)],
            status: .changed,
            relativePath: "a.txt"
        )],
        label: "L",
        changesetUUID: nil,
        wait: true,
        caller: caller,
        clientPID: 7
    )
    let request = Request(operation: .open, invocation: invocation)
    let data = try WireCoding.encode(request)
    #expect(try WireCoding.decode(Request.self, from: data) == request)
    let text = String(decoding: data, as: UTF8.self)
    // Field names are the protocol; slashes stay readable.
    for key in ["\"protocolVersion\":1", "\"operation\":\"open\"", "\"kind\":\"partialChangeset\"",
                "\"relativePath\":\"a.txt\"", "\"temporary\":true", "\"path\":\"/tmp/x/a.txt\""] {
        #expect(text.contains(key), "missing \(key) in \(text)")
    }
}

@Test func replyAndEventRoundTrip() throws {
    let reply = Reply(ok: true, documentID: "doc-1", serverPID: 9, documents: [
        DocumentSummary(id: "doc-1", kind: .diff, title: "t", groupKey: nil, relativePaths: [], isComplete: true, isClosed: false),
    ])
    #expect(try WireCoding.decode(Reply.self, from: WireCoding.encode(reply)) == reply)
    let event = Event(kind: .documentClosed, documentID: "doc-1")
    #expect(try WireCoding.decode(Event.self, from: WireCoding.encode(event)) == event)
}

@Test func groupKeyPrefersUUIDOverProcess() {
    var invocation = Invocation(kind: .partialChangeset, fileLists: [], caller: caller)
    #expect(invocation.groupKey == "PID:42-1700000000.123")
    invocation.changesetUUID = "abc"
    #expect(invocation.groupKey == "UUID:abc")
    invocation.changesetUUID = nil
    invocation.caller.process = nil
    #expect(invocation.groupKey == nil)
}

// MARK: - Framing

@Test func frameHasBigEndianLengthPrefix() throws {
    let frame = try Framing.frame(Data("hello".utf8))
    #expect(Array(frame.prefix(4)) == [0, 0, 0, 5])
    #expect(frame.dropFirst(4) == Data("hello".utf8))
    #expect(try Framing.payloadLength(header: Data([0, 1, 0, 2])) == 65_538)
}

@Test func oversizedFramesAreRejected() {
    #expect(throws: Framing.Error.tooLarge(Framing.maximumPayload + 1)) {
        try Framing.payloadLength(header: withUnsafeBytes(of: UInt32(Framing.maximumPayload + 1).bigEndian) { Data($0) })
    }
}

@Test func decoderReassemblesChunkedFrames() throws {
    var stream = try Framing.frame(Data("first".utf8))
    stream.append(try Framing.frame(Data()))
    stream.append(try Framing.frame(Data("third".utf8)))
    var decoder = FrameDecoder()
    var frames: [Data] = []
    for byte in stream {
        frames += try decoder.append(Data([byte]))
    }
    #expect(frames == [Data("first".utf8), Data(), Data("third".utf8)])
    #expect(decoder.pendingByteCount == 0)
}

private func socketPair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    return (fds[0], fds[1])
}

@Test func framesTravelOverASocket() throws {
    let (a, b) = socketPair()
    defer { close(a); close(b) }
    let big = Data((0..<300_000).map { UInt8($0 % 251) })
    let writer = Thread { try? Framing.write(big, to: a) }
    writer.start()
    #expect(try Framing.read(from: b) == big)
}

@Test func readReportsAClosedPeer() throws {
    let (a, b) = socketPair()
    defer { close(b) }
    // Half a header, then end of file.
    _ = [UInt8(0), 0].withUnsafeBytes { write(a, $0.baseAddress, 2) }
    close(a)
    #expect(throws: Framing.Error.closed) { try Framing.read(from: b) }
}

// MARK: - Sockets

/// A short directory for sockets: temporary paths can exceed sun_path.
func shortSocketDirectory() throws -> URL {
    var template = Array("/tmp/prism-t.XXXXXX".utf8CString)
    guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
    return URL(fileURLWithPath: String(cString: made), isDirectory: true)
}

@Test func listeningSocketIsPrivateToTheUser() throws {
    let root = try shortSocketDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "d/s.sock").path
    let fd = try UnixSocket.listen(at: path)
    defer { close(fd) }
    let file = try FileManager.default.attributesOfItem(atPath: path)
    let folder = try FileManager.default.attributesOfItem(atPath: root.appending(path: "d").path)
    #expect((file[.posixPermissions] as? Int) == 0o600)
    #expect((folder[.posixPermissions] as? Int) == 0o700)
    #expect((file[.type] as? FileAttributeType) == .typeSocket)

    let client = try UnixSocket.connect(to: path)
    defer { close(client) }
    let server = accept(fd, nil, nil)
    defer { close(server) }
    #expect(UnixSocket.peerUID(server) == getuid())
    #expect(UnixSocket.peerPID(server) == getpid())
}

@Test func connectingWhereNothingListensMeansNoServer() throws {
    let root = try shortSocketDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        _ = try UnixSocket.connect(to: root.appending(path: "none.sock").path)
        Issue.record("connect succeeded")
    } catch let error as UnixSocket.Error {
        #expect(error.meansNoServer)
    }
}

@Test func overlongSocketPathsAreRejected() {
    let path = "/tmp/" + String(repeating: "x", count: 200)
    #expect(throws: UnixSocket.Error.pathTooLong(path)) { try UnixSocket.connect(to: path) }
}

@Test func socketPathHonoursTheOverride() {
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(IPCEnvironment.socketPath(environment: [:], home: home)
            == "/Users/someone/Library/Application Support/Prism/prism.sock")
    #expect(IPCEnvironment.socketPath(environment: ["PRISM_SOCKET_PATH": "/tmp/x.sock"], home: home) == "/tmp/x.sock")
    #expect(IPCEnvironment.socketPath(environment: ["PRISM_SOCKET_PATH": ""], home: home).hasSuffix("prism.sock"))
}

@Test func clientReportsAMissingServer() throws {
    let root = try shortSocketDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = IPCClient(socketPath: root.appending(path: "none.sock").path)
    #expect(!client.isServerRunning())
    do {
        _ = try client.send(Request(operation: .ping))
        Issue.record("send succeeded")
    } catch {
        guard case .notRunning = error else { Issue.record("unexpected \(error)"); return }
    }
}
