// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Testing

/// The header and the `merged` value of `Merge3Result.json`.
@Suite struct Merge3JSONTests {

    @Test func startsWithFormatAndVersion() throws {
        let result = try Merge3.merge(base: Array("x\n".utf8), a: Array("x\n".utf8), b: Array("y\n".utf8))
        #expect(result.json.hasPrefix("{\n  \"format\": \"prism-merge3\",\n  \"version\": 1,\n  \"whitespace\": 0,\n"))
        #expect(result.json.contains("\n  \"merged\": \"y\\n\"\n}\n"))
    }

    @Test func invalidUTF8MergedTextIsWrittenAsLines() throws {
        let base = Array("ok\nx\n".utf8)
        let a: [UInt8] = Array("ok\n".utf8) + [0xFF, 0x41, 0x0A]
        let result = try Merge3.merge(base: base, a: a, b: base)
        #expect(result.merged == a)
        #expect(result.json.contains("\n  \"merged\": [\"ok\\n\", [255, 65, 10]]\n}\n"))
    }

    @Test func emptyMergeIsAnEmptyString() throws {
        let result = try Merge3.merge(base: [], a: [], b: [])
        #expect(result.json.contains("\"merged\": \"\"\n"))
    }
}
