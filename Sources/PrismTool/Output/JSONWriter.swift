// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// The `prism diff --json` document (schema in docs/spec-public/prism-cli.md).
///
///     {"format":"prism-diff","version":1,"whitespace":0,"changes":8,"blocks":[
///     {"kind":"equal","a":[0,3],"b":[0,3]},
///     {"kind":"change","a":[3,4],"b":[3,4],"words":[{"aLine":3,"bLine":3,"a":[4,9],"b":[4,13],"aUTF16":[4,9],"bUTF16":[4,13]}]},
///     ...
///     ]}
///
/// One block per line, keys in a fixed order, no file names, LF endings: the
/// output depends only on the two inputs and the whitespace mode.
enum JSONWriter {
    static let format = "prism-diff"
    static let version = 1

    static func write(_ result: TextDiffResult, a: [UInt8], b: [UInt8],
                      whitespace: WhitespaceMode, to out: inout ChunkedOutput) {
        out.append("{\"format\":\"\(format)\",\"version\":\(version)"
                   + ",\"whitespace\":\(whitespace.rawValue),\"changes\":\(result.changeCount),\"blocks\":[")
        var columnsA = UTF16Cursor(buffer: a, lines: result.linesA)
        var columnsB = UTF16Cursor(buffer: b, lines: result.linesB)
        for (index, block) in result.blocks.enumerated() {
            var line = index == 0 ? "\n" : ",\n"
            line += "{\"kind\":\"\(block.kind.rawValue)\",\"a\":\(range(block.a)),\"b\":\(range(block.b))"
            if block.kind == .change {
                line += ",\"words\":["
                for (k, hunk) in block.words.enumerated() {
                    if k > 0 { line += "," }
                    let aUTF16 = columnsA.columns(hunk.a, line: hunk.aLine)
                    let bUTF16 = columnsB.columns(hunk.b, line: hunk.bLine)
                    line += "{\"aLine\":\(hunk.aLine),\"bLine\":\(hunk.bLine)"
                    line += ",\"a\":\(range(hunk.a)),\"b\":\(range(hunk.b))"
                    line += ",\"aUTF16\":\(range(aUTF16)),\"bUTF16\":\(range(bUTF16))}"
                }
                line += "]"
            }
            line += "}"
            out.append(line)
        }
        out.append(result.blocks.isEmpty ? "]}\n" : "\n]}\n")
    }

    static func range(_ range: Range<Int>) -> String {
        "[\(range.lowerBound),\(range.upperBound)]"
    }
}

/// Converts byte columns to UTF-16 columns line by line.
///
/// Word hunks of a line come in increasing column order, so the cursor
/// counts on from the previous hunk instead of from the line start each
/// time: O(line length) per line rather than per hunk. Counting in pieces
/// is exact because hunk boundaries are token boundaries, and the tokenizer
/// never splits a run of bytes >= 0x80, so no UTF-8 sequence (well-formed
/// or not) straddles a boundary.
struct UTF16Cursor {
    let buffer: [UInt8]
    let lines: LineIndex
    private var line = -1
    private var byteColumn = 0
    private var unitColumn = 0

    init(buffer: [UInt8], lines: LineIndex) {
        self.buffer = buffer
        self.lines = lines
    }

    /// UTF-16 columns of the byte columns `range` of `line`.
    mutating func columns(_ range: Range<Int>, line target: Int) -> Range<Int> {
        let lower = advance(to: range.lowerBound, line: target)
        let upper = range.isEmpty ? lower : advance(to: range.upperBound, line: target)
        return lower ..< upper
    }

    private mutating func advance(to column: Int, line target: Int) -> Int {
        if target != line || column < byteColumn {
            line = target
            byteColumn = 0
            unitColumn = 0
        }
        let start = lines.range(target).lowerBound
        unitColumn += UTF16Columns.count(buffer, from: start + byteColumn, to: start + column)
        byteColumn = column
        return unitColumn
    }
}
