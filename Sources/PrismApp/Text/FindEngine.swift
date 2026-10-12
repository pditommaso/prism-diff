// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation

/// Literal text search over one side of a comparison: case- and
/// diacritic-insensitive, never across a line break.
enum FindEngine {
    static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every match of `query` in `text`, in document order. Returns early
    /// (with what it found so far) when `cancelled` turns true.
    static func search(_ text: ComparisonSide, side: DiffSide, query: String,
                       cancelled: @Sendable () -> Bool = { false }) -> [FindMatch] {
        guard !query.isEmpty, !query.contains(where: \.isNewline), !text.bytes.isEmpty else { return [] }
        // UTF-16 offset of every line start, and of every content end.
        var starts = [Int](), ends = [Int]()
        starts.reserveCapacity(text.lineCount + 1)
        ends.reserveCapacity(text.lineCount)
        var units = 0
        text.bytes.withUnsafeBufferPointer { bytes in
            for line in 0 ..< text.lineCount {
                starts.append(units)
                let content = text.contentRange(line)
                for index in content where bytes[index] & 0xC0 != 0x80 {
                    units += bytes[index] >= 0xF0 ? 2 : 1
                }
                ends.append(units)
                units += text.lines.range(line).upperBound - content.upperBound
            }
        }
        starts.append(units)
        // A native NSString: searching a bridged Swift string is slower.
        guard let string = text.bytes.withUnsafeBufferPointer({ bytes in
            NSString(bytes: bytes.baseAddress!, length: bytes.count, encoding: String.Encoding.utf8.rawValue)
        }) else { return [] }
        // NSString drops a leading U+FEFF that the line offsets count: put
        // that unit back into every location.
        let shift = text.bytes.starts(with: [0xEF, 0xBB, 0xBF]) && string.length == units - 1 ? 1 : 0
        var matches: [FindMatch] = []
        var location = 0
        var line = 0
        while location < string.length {
            if cancelled() { break }
            let found = string.range(of: query, options: options,
                                     range: NSRange(location: location, length: string.length - location))
            if found.location == NSNotFound { break }
            let unit = found.location + shift
            // Lines only move forward: advance instead of searching.
            while line + 1 < starts.count - 1, starts[line + 1] <= unit { line += 1 }
            let end = unit + max(found.length, 1)
            if end <= ends[line] {
                let offset = unit - starts[line]
                matches.append(FindMatch(side: side, line: line, range: offset ..< offset + found.length))
            }
            location = found.location + max(found.length, 1)
        }
        return matches
    }

    /// "1st", "2nd", "3rd", "4th", … "11th", "12th", "13th", "21st".
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11 ... 13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// The find bar's summary and the clickable note about the other side.
    ///
    /// - Parameters:
    ///   - count: matches where the search looks (the scope side, or the
    ///     unified text when `scope` is nil).
    ///   - current: index of the current match, if any.
    ///   - scope: the side searched, nil in Unified.
    ///   - other: matches on the other side.
    static func summary(count: Int, current: Int?, scope: DiffSide?, other: Int) -> (text: String, note: String?) {
        let name = scope.map { $0 == .a ? "A" : "B" }
        let otherName = scope.map { $0 == .a ? "B" : "A" }
        let place = name.map { " in \($0)" } ?? ""
        if count == 0 {
            let note = otherName.flatMap { other > 0 ? "(\(other) in \($0))" : nil }
            return ("No results\(place)", note)
        }
        let noun = count == 1 ? "result" : "results"
        let main = current.map { "\(ordinal($0 + 1)) of \(count) \(noun)\(place)" } ?? "\(count) \(noun)\(place)"
        let note = otherName.map { other > 0 ? "(\(other) more in \($0))" : "(No more in \($0))" }
        return (main, note)
    }
}
