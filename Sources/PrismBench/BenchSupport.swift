// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation

/// Collects check outcomes and prints them in the bench's two formats: a
/// human `PASS`/`FAIL` line and a machine-readable line of `key=value` pairs.
final class BenchReport {
    private(set) var failures = 0
    private(set) var checks = 0

    /// Records one check. `fields` is printed as `key=value` pairs, followed
    /// by `result=pass` or `result=fail`.
    func record(_ passed: Bool, _ message: String, fields: KeyValuePairs<String, String> = [:]) {
        checks += 1
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(message)")
        if fields.count > 0 {
            let pairs = fields.map { "\($0.key)=\($0.value)" } + ["result=\(passed ? "pass" : "fail")"]
            print(pairs.joined(separator: " "))
        }
    }

    /// Prints a `key=value` line that is not a check.
    func info(_ fields: KeyValuePairs<String, String>) {
        print(fields.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }

    /// 0 when at least one check ran and none failed, 1 otherwise.
    var exitStatus: Int32 { failures == 0 && checks > 0 ? 0 : 1 }
}

/// Formats milliseconds with two decimals, for both output formats.
func formatMs(_ value: Double) -> String { String(format: "%.2f", value) }

/// Monotonic time in milliseconds.
func nowMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000 }

/// Locates the test corpus (`Tests/corpus`).
enum BenchCorpus {
    /// `--corpus DIR` wins; then `PRISM_CORPUS_DIR`; then the first
    /// `Tests/corpus` found walking up from the current directory, and
    /// finally from this source file (for `swift run` from elsewhere).
    static func locate(override: String?) -> URL? {
        let fileManager = FileManager.default
        func isCorpus(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appending(path: "fixtures.sha256").path(percentEncoded: false))
        }
        if let path = override ?? ProcessInfo.processInfo.environment["PRISM_CORPUS_DIR"] {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            return isCorpus(url) ? url : nil
        }
        let starts = [URL(filePath: fileManager.currentDirectoryPath, directoryHint: .isDirectory),
                      URL(filePath: #filePath).deletingLastPathComponent()]
        for start in starts {
            var candidate = start
            while candidate.path(percentEncoded: false) != "/" {
                let corpus = candidate.appending(path: "Tests/corpus", directoryHint: .isDirectory)
                if isCorpus(corpus) { return corpus }
                candidate = candidate.deletingLastPathComponent()
            }
        }
        return nil
    }

    static let generateHint = "run /usr/bin/python3 -I Tests/corpus/scripts/generate.py"
}

/// A named input pair of the corpus.
struct BenchPair {
    let name: String
    let a: URL
    let b: URL
    /// True for files written by generate.py, which may be absent.
    let generated: Bool

    static func fixture(_ name: String, _ a: String, _ b: String, in corpus: URL) -> BenchPair {
        let text = corpus.appending(path: "fixtures/text", directoryHint: .isDirectory)
        return BenchPair(name: name, a: text.appending(path: a), b: text.appending(path: b), generated: false)
    }

    static func generated(_ name: String, in corpus: URL) -> BenchPair {
        let directory = corpus.appending(path: "generated", directoryHint: .isDirectory)
        return BenchPair(name: name, a: directory.appending(path: "\(name)_a.txt"),
                         b: directory.appending(path: "\(name)_b.txt"), generated: true)
    }

    /// Why the pair cannot be used, or nil when both files exist.
    var missingReason: String? {
        let fileManager = FileManager.default
        let missing = [a, b].filter { !fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard let first = missing.first else { return nil }
        let what = "missing \(first.path(percentEncoded: false))"
        return generated ? "\(what) (\(BenchCorpus.generateHint))" : what
    }

    /// Both files, memory-mapped.
    func load() throws -> MappedPair {
        MappedPair(a: try Data(contentsOf: a, options: .alwaysMapped),
                   b: try Data(contentsOf: b, options: .alwaysMapped))
    }
}

/// Two memory-mapped inputs, diffed in place without copying.
struct MappedPair: Sendable {
    let a: Data
    let b: Data

    func diff(_ options: DiffOptions = DiffOptions()) -> TextDiffResult {
        a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                TextDiff.diff(ra.bindMemory(to: UInt8.self), rb.bindMemory(to: UInt8.self), options: options)
            }
        }
    }

    func cancellableDiff(_ options: DiffOptions) throws(DiffError) -> TextDiffResult {
        let outcome: Result<TextDiffResult, DiffError> = a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                Result { () throws(DiffError) in
                    try TextDiff.cancellableDiff(ra.bindMemory(to: UInt8.self), rb.bindMemory(to: UInt8.self),
                                                 options: options)
                }
            }
        }
        return try outcome.get()
    }
}
