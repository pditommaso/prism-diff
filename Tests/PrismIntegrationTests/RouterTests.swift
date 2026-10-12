// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismProtocol
@testable import PrismIntegration

private func makeRouter(idle: TimeInterval = 10, sweep: TimeInterval = 2) -> (ChangesetRouter, RecordingSink) {
    let sink = RecordingSink()
    return (ChangesetRouter(sink: sink, snapshots: nil, idleTimeout: idle, sweepInterval: sweep), sink)
}

private func open(_ router: ChangesetRouter, _ invocation: Invocation) -> String? {
    router.handle(Request(operation: .open, invocation: invocation)).documentID
}

private func partial(_ name: String, caller info: CallerInfo = caller(), uuid: String? = nil,
                     status: FileStatus = .changed) -> Invocation {
    Invocation(kind: .partialChangeset, fileLists: [pair("/t/\(name)", "/w/repo/\(name)", relative: name, status: status)],
               changesetUUID: uuid, caller: info)
}

/// A child process to stand in for a running git.
private func spawnSleeper(_ seconds: String) throws -> (Process, ProcessIdentity) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = [seconds]
    try process.run()
    let record = try #require(ProcessTable.record(of: process.processIdentifier))
    return (process, record.identity)
}

@Suite struct RouterTests {
    @Test func plainDiffsOpenSeparateDocuments() {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let diff = Invocation(kind: .diff, fileLists: [pair("/a", "/b")], caller: caller())
        let first = open(router, diff)
        let second = open(router, diff)
        #expect(first != nil && first != second)
        #expect(sink.documents.count == 2)
        #expect(sink.documents[0].title == nil)
        #expect(sink.documents[0].isComplete)
        #expect(sink.documents[0].entries[0].files.map(\.path) == ["/a", "/b"])
    }

    @Test func labelBecomesTheTitle() {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        _ = open(router, Invocation(kind: .diff, fileLists: [pair("/a", "/b")], label: "Mine", caller: caller()))
        #expect(sink.documents[0].title == "Mine")
    }

    @Test func partialsFromOneCallerShareAChangeset() throws {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let (sleeper, identity) = try spawnSleeper("5")
        defer { sleeper.terminate() }
        let git = CallerInfo(process: identity, name: "git", arguments: ["git", "diff"], tool: .git, workingDirectory: "/w/repo")
        let ids = ["a.txt", "b.txt", "c.txt"].map { open(router, partial($0, caller: git)) }
        #expect(Set(ids).count == 1)
        #expect(sink.documents.count == 1)
        let document = sink.documents[0]
        #expect(document.title == "Changes in repo")
        #expect(document.tool == .git)
        #expect(document.entries.map(\.relativePath) == ["a.txt", "b.txt", "c.txt"])
        #expect(!document.isComplete)
        #expect(router.status()[0].groupKey == identity.groupKey)
    }

    @Test func differentCallersGetDifferentChangesets() throws {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let (one, first) = try spawnSleeper("5")
        let (two, second) = try spawnSleeper("5")
        defer { one.terminate(); two.terminate() }
        for index in 0..<6 {
            let identity = index.isMultiple(of: 2) ? first : second
            _ = open(router, partial("f\(index)", caller: CallerInfo(
                process: identity, name: "git", arguments: ["git", "diff"], tool: .git, workingDirectory: "/w/repo")))
        }
        #expect(sink.documents.map { $0.entries.count } == [3, 3])
        #expect(sink.documents[0].entries.map(\.relativePath) == ["f0", "f2", "f4"])
    }

    @Test func changesetCompletesWhenTheCallerExits() throws {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let (sleeper, identity) = try spawnSleeper("0.2")
        let git = CallerInfo(process: identity, name: "git", arguments: ["git", "diff"], tool: .git, workingDirectory: "/w/repo")
        let id = try #require(open(router, partial("a", caller: git)))
        #expect(sink.document(id)?.isComplete == false)
        sleeper.waitUntilExit()
        #expect(eventually { sink.document(id)?.isComplete == true })
        // A late pair from a process that has gone opens a new document.
        let late = open(router, partial("b", caller: git))
        #expect(late != id)
        #expect(eventually { sink.documents.count == 2 && sink.documents[1].isComplete })
    }

    @Test func callerThatAlreadyExitedCompletesAtOnce() {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        // PID 4242 with start time 1 is not running.
        let id = open(router, partial("a"))
        router.drain()
        #expect(sink.documents.first?.id == id)
        #expect(sink.documents.first?.isComplete == true)
    }

    @Test func closedChangesetIsNotReopened() throws {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let (sleeper, identity) = try spawnSleeper("5")
        defer { sleeper.terminate() }
        let git = CallerInfo(process: identity, name: "git", arguments: ["git", "diff"], tool: .git, workingDirectory: "/w/repo")
        let first = try #require(open(router, partial("a", caller: git)))
        router.documentClosed(first)
        router.drain()
        #expect(router.closedChangesetKeys == [identity.groupKey])
        let second = try #require(open(router, partial("b", caller: git)))
        #expect(second != first)
        #expect(sink.documents.count == 2)
        #expect(router.closedChangesetKeys.isEmpty)
        // Later pairs join the new document.
        #expect(open(router, partial("c", caller: git)) == second)
        #expect(sink.document(second)?.entries.map(\.relativePath) == ["b", "c"])
    }

    @Test func uuidChangesetsGroupAndCloseOnRequest() {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let a = open(router, partial("a", caller: caller(pid: 1), uuid: "U1"))
        let b = open(router, partial("b", caller: caller(pid: 2), uuid: "U1"))
        let c = open(router, partial("c", caller: caller(pid: 1), uuid: "U2"))
        #expect(a == b && a != c)
        #expect(sink.document(a!)?.isComplete == false)
        #expect(router.handle(Request(operation: .markChangesetClosed, changesetUUID: "U1")).ok)
        router.drain()
        #expect(sink.document(a!)?.isComplete == true)
        let d = open(router, partial("d", caller: caller(pid: 1), uuid: "U1"))
        #expect(d != a)
        // Marking an unknown changeset is not an error.
        #expect(router.handle(Request(operation: .markChangesetClosed, changesetUUID: "nope")).ok)
        #expect(!router.handle(Request(operation: .markChangesetClosed)).ok)
    }

    @Test func idleUUIDChangesetCompletes() {
        let (router, sink) = makeRouter(idle: 0.2, sweep: 0.05)
        defer { router.shutdown() }
        let id = open(router, partial("a", uuid: "idle"))!
        #expect(sink.document(id)?.isComplete == false)
        #expect(eventually { sink.document(id)?.isComplete == true })
    }

    @Test func wholeChangesetIsOneCompleteDocument() {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let id = open(router, Invocation(kind: .changeset, fileLists: [
            pair("/l/a", "/r/a", relative: "a"),
            pair(IPCProtocol.placeholderPath, "/r/b", relative: "b", status: .added),
            pair("/l/c", IPCProtocol.placeholderPath, relative: "c", status: .removed),
        ], caller: caller()))
        let document = sink.document(id!)!
        #expect(document.isComplete)
        #expect(document.entries.map(\.status) == [.changed, .added, .removed])
        #expect(document.entries[1].files[0].isPlaceholder)
        #expect(document.title == "Changes in repo")
    }

    @Test func entriesWithoutRelativePathUseTheFileName() {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        _ = open(router, Invocation(kind: .changeset, fileLists: [pair("/l/x.txt", "/r/y.txt")], caller: caller()))
        #expect(sink.documents[0].entries[0].relativePath == "y.txt")
    }

    @Test func emptyOpenIsRefused() {
        let (router, _) = makeRouter()
        defer { router.shutdown() }
        #expect(!router.handle(Request(operation: .open)).ok)
        #expect(!router.handle(Request(operation: .open, invocation: Invocation(kind: .diff, fileLists: [], caller: caller()))).ok)
    }

    @Test func rowsForAClosedWindowAreRedelivered() throws {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let (sleeper, identity) = try spawnSleeper("5")
        defer { sleeper.terminate() }
        let git = CallerInfo(process: identity, name: "git", arguments: ["git", "diff"], tool: .git, workingDirectory: "/w/repo")
        let first = try #require(open(router, partial("a", caller: git)))
        _ = open(router, partial("b", caller: git))
        // The window closed before the app showed row "b".
        router.documentClosed(first)
        let lost = try #require(sink.document(first)?.entries.last)
        router.redeliver([lost], fromClosed: first)
        let documents = sink.documents
        #expect(documents.count == 2)
        #expect(documents[1].entries.map(\.relativePath) == ["b"])
        #expect(documents[1].title == "Changes in repo")
        #expect(documents[1].tool == .git)
        #expect(!documents[1].isComplete)
        // Later pairs from the same run join the new document.
        #expect(open(router, partial("c", caller: git)) == documents[1].id)
        // Redelivery to an open document is ignored.
        router.redeliver([lost], fromClosed: documents[1].id)
        #expect(sink.documents.count == 2)
    }

    @Test func closedDocumentGetsNoNewPairsOnceCloseReturns() throws {
        let (router, sink) = makeRouter()
        defer { router.shutdown() }
        let (sleeper, identity) = try spawnSleeper("5")
        defer { sleeper.terminate() }
        let git = CallerInfo(process: identity, name: "git", arguments: ["git", "diff"], tool: .git, workingDirectory: "/w/repo")
        let first = try #require(open(router, partial("a", caller: git)))
        router.documentClosed(first)          // synchronous: no drain needed
        #expect(open(router, partial("b", caller: git)) != first)
        #expect(sink.documents.count == 2)
    }

    @Test func waiterGetsTheEventOnlyAfterArming() {
        let (router, _) = makeRouter()
        defer { router.shutdown() }
        let received = EventBox()
        let waiter = Waiter { received.append($0) }
        let reply = router.handle(Request(operation: .open, invocation: Invocation(
            kind: .diff, fileLists: [pair("/a", "/b")], wait: true, caller: caller())), waiter: waiter)
        let id = reply.documentID!
        router.documentClosed(id)
        router.drain()
        #expect(received.events.isEmpty)     // held back until the reply is out
        waiter.arm()
        #expect(received.events == [Event(kind: .documentClosed, documentID: id)])
        router.documentClosed(id)            // a second close is ignored
        router.drain()
        #expect(received.events.count == 1)
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Event] = []
    func append(_ event: Event) { lock.withLock { stored.append(event) } }
    var events: [Event] { lock.withLock { stored } }
}
