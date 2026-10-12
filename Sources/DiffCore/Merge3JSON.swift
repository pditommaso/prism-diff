// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

// Canonical JSON form of a three-way merge. It is what `prism merge3 --json`
// prints and what the goldens under Tests/corpus/merge store, so the output
// must stay byte-stable: fixed key order, one region per line, LF endings.

extension Merge3Result {

    /// The merge as JSON, ending with a newline:
    ///
    ///     {
    ///       "format": "prism-merge3",
    ///       "version": 1,
    ///       "whitespace": 0,
    ///       "conflicts": 1,
    ///       "unresolved": 1,
    ///       "regions": [
    ///         {"kind": "equal", "choice": "none", "a": [0, 1], "b": [0, 1], "base": [0, 1], "merged": [0, 1]},
    ///         ...
    ///       ],
    ///       "merged": "..."
    ///     }
    ///
    /// Ranges are 0-based half-open line ranges written as [start, end].
    /// `merged` is the merged text as one string when it is valid UTF-8.
    /// Otherwise it is an array with one entry per merged line (terminator
    /// included): a string for a line that is valid UTF-8, or an array of its
    /// byte values for one that is not, so no byte is lost.
    public var json: String {
        var out = "{\n"
        out += "  \"format\": \"prism-merge3\",\n"
        out += "  \"version\": 1,\n"
        out += "  \"whitespace\": \(whitespace.rawValue),\n"
        out += "  \"conflicts\": \(conflictCount),\n"
        out += "  \"unresolved\": \(unresolvedConflictCount),\n"
        out += "  \"regions\": ["
        for (i, region) in regions.enumerated() {
            out += i == 0 ? "\n" : ",\n"
            out += "    {\"kind\": \"\(region.kind.rawValue)\", \"choice\": \"\(region.choice.name)\""
            out += ", \"a\": \(Self.json(region.aRange)), \"b\": \(Self.json(region.bRange))"
            out += ", \"base\": \(Self.json(region.baseRange))"
            out += ", \"merged\": \(Self.json(region.mergedRange))}"
        }
        out += regions.isEmpty ? "],\n" : "\n  ],\n"
        out += "  \"merged\": \(mergedJSON)\n"
        out += "}\n"
        return out
    }

    /// The value of the `merged` key; see `json`.
    private var mergedJSON: String {
        if Self.isValidUTF8(merged[...]) {
            return Self.jsonString(String(decoding: merged, as: UTF8.self))
        }
        var out = "["
        for line in 0 ..< mergedLines.count {
            let bytes = merged[mergedLines.range(line)]
            out += line == 0 ? "" : ", "
            if Self.isValidUTF8(bytes) {
                out += Self.jsonString(String(decoding: bytes, as: UTF8.self))
            } else {
                out += "[" + bytes.map { String($0) }.joined(separator: ", ") + "]"
            }
        }
        return out + "]"
    }

    /// True when `bytes` is well-formed UTF-8.
    static func isValidUTF8(_ bytes: ArraySlice<UInt8>) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    static func json(_ range: Range<Int>) -> String {
        "[\(range.lowerBound), \(range.upperBound)]"
    }

    /// A JSON string literal. Quote, backslash and control characters are
    /// escaped; everything else is written as is.
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
