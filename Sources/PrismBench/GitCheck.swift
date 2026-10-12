// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
import DiffCore
import Foundation

/// `gitcheck`: line-hunk counts against `git diff --no-index --patience -U0`.
enum GitCheckBench {
    static func pairs(corpus: URL) -> [BenchPair] {
        [
            .fixture("ab", "a.swift", "b.swift", in: corpus),
            .fixture("big", "big_a.txt", "big_b.txt", in: corpus),
            .fixture("slider", "slider_a.groovy", "slider_b.groovy", in: corpus),
            .generated("m1", in: corpus),
            .generated("diff20k", in: corpus),
        ]
    }

    static func run(corpus: URL, report: BenchReport) {
        report.info(["bench": "gitcheck"])
        let home: URL
        do {
            home = FileManager.default.temporaryDirectory
                .appending(path: "prism-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            report.record(false, "cannot create a temporary HOME for git: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: home) }

        for pair in pairs(corpus: corpus) {
            if let reason = pair.missingReason {
                report.record(false, "\(pair.name): \(reason)", fields: ["case": pair.name, "missing": "1"])
                continue
            }
            let ours: Int
            do {
                ours = LineHunks.count(try pair.load().diff())
            } catch {
                report.record(false, "\(pair.name): cannot read input: \(error.localizedDescription)",
                              fields: ["case": pair.name])
                continue
            }
            switch GitPatience.hunkCount(pair.a, pair.b, home: home) {
            case .failure(let message):
                report.record(false, "\(pair.name): git failed: \(message)",
                              fields: ["case": pair.name, "prism": String(ours)])
            case .success(let git):
                report.record(ours == git,
                              "\(pair.name): prism \(ours) hunks, git --patience \(git) hunks",
                              fields: ["case": pair.name, "prism": String(ours), "git": String(git)])
            }
        }
    }
}

/// Runs `git diff --no-index --patience -U0` in a sealed environment: no
/// user or system configuration and a throw-away HOME.
enum GitPatience {
    struct Failure: Error {
        let message: String
    }

    static func hunkCount(_ a: URL, _ b: URL, home: URL) -> Result<Int, Failure> {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "diff", "--no-index", "--patience", "-U0", "--no-color", "--no-ext-diff",
                             "--", a.path(percentEncoded: false), b.path(percentEncoded: false)]
        var environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                           "HOME": home.path(percentEncoded: false)]
        environment["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        process.environment = environment
        process.currentDirectoryURL = home
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        // Read both pipes before waiting, so a large diff cannot fill a pipe
        // and stall git. stderr is small; drain it on another thread.
        let errorText = ErrorDrain(errors.fileHandleForReading)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationStatus
        // git diff --no-index exits 1 when the files differ.
        guard process.terminationReason == .exit, status == 0 || status == 1 else {
            return .failure(Failure(message: "exit status \(status): \(errorText.text())"))
        }
        return .success(LineHunks.headerCount(inUnifiedDiff: String(decoding: data, as: UTF8.self)))
    }

    /// Reads a pipe to its end on a background queue.
    final class ErrorDrain: @unchecked Sendable {
        // `data` is written once by the reader before it signals, and read
        // only after waiting on the semaphore.
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global().async {
                self.data = handle.readDataToEndOfFile()
                self.done.signal()
            }
        }

        func text() -> String {
            done.wait()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
