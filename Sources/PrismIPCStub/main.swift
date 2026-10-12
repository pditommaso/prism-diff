// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

// A headless stand-in for the Prism app's socket server, for acceptance
// scripts and tests. Not shipped.
//
//   PrismIPCStub serve  --socket PATH [--close-after-ms N] [--ready-file F]
//                       [--merge-choice none|a|b|aThenB|bThenA]
//       Serves until SIGTERM or SIGINT. SIGUSR1 closes every open document,
//       as if the user closed its window (a merge closes unresolved).
//       --close-after-ms closes each new document N ms after it opens. A
//       merge closed that way is first merged headlessly (DiffCore) with
//       every conflict given --merge-choice: any choice but none (the
//       default) saves the result to the output file and reports the
//       merge resolved; none saves nothing and reports it unresolved.
//   PrismIPCStub status --socket PATH
//       Prints the server's document list as JSON.
//   PrismIPCStub bench  --socket PATH [--count N] [--op open|mark]
//       Times N fresh-connection round trips (after 20 warm-up ones) and
//       prints min/median/p95/max in ms as JSON. `open` sends a two-file
//       diff (each opens a document); `mark` marks an unknown changeset
//       closed, which goes through the router but opens nothing (use it
//       against the real app).

import DiffCore
import Foundation
import PrismIntegration
import PrismProtocol

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("PrismIPCStub: \(message)\n".utf8))
    exit(2)
}

let allArguments = Array(CommandLine.arguments.dropFirst())
guard let command = allArguments.first else { fail("usage: PrismIPCStub serve|status|bench --socket PATH") }

func option(_ name: String) -> String? {
    let arguments = Array(allArguments.dropFirst())
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let socketPath = option("--socket") ?? IPCEnvironment.socketPath()

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { fail("cannot encode output") }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// The router, set once the server is up (sinks need it to close documents).
final class RouterBox: @unchecked Sendable {
    var router: ChangesetRouter?
}

/// The stub's stand-in for a user resolving a merge window.
enum HeadlessMerge {
    /// Merges a merge document's files headlessly, resolves every conflict
    /// with `choice` and saves the result to its output. Returns whether the
    /// merge counts as resolved.
    static func resolve(_ document: DocumentContent, choice: DiffCore.MergeChoice) -> Bool {
        guard choice != .none, let output = document.mergeOutput, let files = document.entries.first?.files,
              files.count >= 2 else { return false }
        func read(_ path: String) -> [UInt8]? { FileManager.default.contents(atPath: path).map { [UInt8]($0) } }
        guard let a = read(files[0].path), let b = read(files[1].path) else { return false }
        // Without a base every difference is a conflict.
        let merged = files.count > 2 ? try? Merge3.merge(base: read(files[2].path) ?? [], a: a, b: b)
                                     : try? Merge3.mergeWithoutBase(a: a, b: b)
        guard var result = merged else { return false }
        for index in result.regions.indices where result.regions[index].kind == .conflict {
            result = result.applying(choice: choice, to: index)
        }
        return FileManager.default.createFile(atPath: output, contents: Data(result.merged))
    }
}

switch command {
case "serve":
    let closeAfter = option("--close-after-ms").flatMap(Int.init)
    let mergeChoice: DiffCore.MergeChoice = switch option("--merge-choice") ?? "none" {
    case "none": .none
    case "a": .a
    case "b": .b
    case "aThenB": .aThenB
    case "bThenA": .bThenA
    case let other: fail("unknown --merge-choice '\(other)'")
    }
    let box = RouterBox()
    let sink = RecordingSink { @Sendable document in
        guard let closeAfter, document.entries.count == 1 || document.kind != .partialChangeset else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(closeAfter)) {
            if document.kind == .merge {
                box.router?.mergeFinished(document.id, resolved: HeadlessMerge.resolve(document, choice: mergeChoice))
            } else {
                box.router?.documentClosed(document.id)
            }
        }
    }
    let router = ChangesetRouter(sink: sink, snapshots: .temporary())
    box.router = router
    let server = IPCServer(socketPath: socketPath, router: router)
    do {
        try server.start()
    } catch {
        fail("\(error)")
    }
    if let readyFile = option("--ready-file") {
        FileManager.default.createFile(atPath: readyFile, contents: Data("\(getpid())\n".utf8))
    }
    var sources: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT, SIGUSR1] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { @Sendable in
            if signalNumber == SIGUSR1 {
                for document in router.status() where !document.isClosed {
                    router.documentClosed(document.id)
                }
                return
            }
            server.stop()
            router.shutdown()
            exit(0)
        }
        source.resume()
        sources.append(source)
    }
    dispatchMain()

case "status":
    do {
        let (reply, _) = try IPCClient(socketPath: socketPath).send(Request(operation: .status), timeout: 10)
        printJSON(reply.documents ?? [])
    } catch {
        fail("\(error)")
    }

case "bench":
    let count = option("--count").flatMap(Int.init) ?? 200
    let folder = FileManager.default.temporaryDirectory.appending(path: "prism-ipc-bench-\(getpid())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = folder.appending(path: "a.txt").path
    let b = folder.appending(path: "b.txt").path
    FileManager.default.createFile(atPath: a, contents: Data("a\n".utf8))
    FileManager.default.createFile(atPath: b, contents: Data("b\n".utf8))
    let invocation = Invocation(
        kind: .diff,
        fileLists: [FileList(files: [FileReference(path: a, temporary: false), FileReference(path: b, temporary: false)])],
        caller: CallerInfo(process: nil, name: "bench", arguments: [], tool: .unknown, workingDirectory: folder.path)
    )
    let client = IPCClient(socketPath: socketPath)
    let request = option("--op") == "mark"
        ? Request(operation: .markChangesetClosed, changesetUUID: "bench-\(getpid())")
        : Request(operation: .open, invocation: invocation)
    var samples: [Double] = []
    for round in 0..<(count + 20) {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try client.send(request, timeout: 5)
        } catch {
            fail("\(error)")
        }
        if round >= 20 {
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
    }
    samples.sort()
    func percentile(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count - 1) * p + 0.5))] }
    printJSON([
        "count": Double(samples.count),
        "min_ms": samples.first ?? 0,
        "median_ms": percentile(0.5),
        "p95_ms": percentile(0.95),
        "max_ms": samples.last ?? 0,
    ])

default:
    fail("unknown command '\(command)'")
}
