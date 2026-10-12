// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// The outcome of comparing a test's output with a golden file.
public enum GoldenResult: Equatable, Sendable {
    /// The output is byte-identical to the golden file.
    case matched
    /// Update mode was on, so the golden file was (re)written.
    case updated
    /// The output differs, the golden file is missing, or it could not be
    /// read or written. The message explains what and where.
    case mismatch(String)

    /// True for `.matched` and `.updated`.
    public var passed: Bool {
        if case .mismatch = self { return false }
        return true
    }

    /// A description suitable for a test failure.
    public var message: String {
        switch self {
        case .matched: "golden file matches"
        case .updated: "golden file updated"
        case .mismatch(let text): text
        }
    }
}

/// Compares test output with files under `Tests/corpus/golden`.
///
/// Comparison is byte-exact on the UTF-8 encoding of the output. Set
/// `PRISM_UPDATE_GOLDEN=1` in the environment to write the current output
/// to the golden file instead; review and commit the result.
public enum Golden {
    /// The environment variable that switches on update mode.
    public static let updateVariable = "PRISM_UPDATE_GOLDEN"

    /// Checks `actual` against `Tests/corpus/golden/<name>`.
    public static func check(_ actual: String, against name: String) -> GoldenResult {
        check(actual, against: name, in: Corpus.goldenDirectory,
              environment: ProcessInfo.processInfo.environment)
    }

    /// Checks `actual` against `<directory>/<name>`, reading update mode
    /// from `environment`.
    public static func check(
        _ actual: String,
        against name: String,
        in directory: URL,
        environment: [String: String]
    ) -> GoldenResult {
        guard isValidName(name) else {
            return .mismatch("invalid golden name '\(name)': use a relative path without '..'")
        }
        let file = directory.appending(path: name, directoryHint: .notDirectory)
        let actualData = Data(actual.utf8)

        if environment[updateVariable] == "1" {
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try actualData.write(to: file, options: .atomic)
                return .updated
            } catch {
                return .mismatch("cannot write golden '\(name)': \(error.localizedDescription)")
            }
        }

        guard let expectedData = try? Data(contentsOf: file) else {
            return .mismatch(
                "golden '\(name)' is missing at \(file.path(percentEncoded: false)); "
                + "run with \(updateVariable)=1 to create it")
        }
        if expectedData == actualData {
            return .matched
        }
        return .mismatch(
            "golden '\(name)' differs: "
            + firstDifference(expected: expectedData, actual: actualData)
            + "\n(run with \(updateVariable)=1 to accept the new output)")
    }

    /// Describes the first differing line between two texts, unified-diff
    /// style: its 1-based line number, then the expected (`-`) and actual
    /// (`+`) lines.
    static func firstDifference(expected: Data, actual: Data) -> String {
        let expectedLines = lines(of: expected)
        let actualLines = lines(of: actual)
        let count = max(expectedLines.count, actualLines.count)
        for index in 0..<count {
            let left = index < expectedLines.count ? expectedLines[index] : nil
            let right = index < actualLines.count ? actualLines[index] : nil
            if left != right {
                return "first difference at line \(index + 1)\n"
                    + "@@ line \(index + 1) @@\n"
                    + "-\(render(left))\n"
                    + "+\(render(right))"
            }
        }
        // Identical lines but different bytes cannot happen with this
        // splitting; keep a safe fallback.
        return "contents differ (\(expected.count) bytes expected, \(actual.count) bytes actual)"
    }

    /// Splits on "\n", keeping each line's terminator so a missing final
    /// newline or a stray "\r" counts as a difference.
    private static func lines(of data: Data) -> [Data] {
        var result: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == UInt8(ascii: "\n") {
            result.append(data[start...index])
            start = data.index(after: index)
        }
        if start < data.endIndex {
            result.append(data[start...])
        }
        return result
    }

    /// Shows a line with its terminator made visible.
    private static func render(_ line: Data?) -> String {
        guard let line else { return "<end of file>" }
        var text = String(decoding: line, as: UTF8.self)
        var terminator = "<no newline at end of file>"
        if text.hasSuffix("\r\n") {
            text.removeLast()
            terminator = "\\r\\n"
        } else if text.hasSuffix("\n") {
            text.removeLast()
            terminator = ""
        }
        return text + terminator
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/")
            && !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
