// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation
import PrismTestSupport
import Testing

/// The refinement valve (`maxRefineTokens`) and line-level-only diffs.
@Suite struct RefinementValveTests {
    /// One long line of `count` numbered fields with `edits` of them changed.
    static func longLine(fields count: Int, edited: Set<Int>) -> [UInt8] {
        var text = ""
        for i in 0 ..< count {
            text += edited.contains(i) ? "{\"k\(i)\":\"changed\"}," : "{\"k\(i)\":\"value\"},"
        }
        return Array((text + "\n").utf8)
    }

    @Test func oneLineAgainstOneLineHasSixteenTimesTheValve() {
        // About 50,000 tokens per side between the first and last edit:
        // far over a valve of 10,000, but within the line-pair limit of
        // 16 x 10,000 that one line against one line gets.
        let a = Self.longLine(fields: 5000, edited: [])
        let b = Self.longLine(fields: 5000, edited: [10, 2500, 4990])
        let result = TextDiff.diff(a, b, options: DiffOptions(maxRefineTokens: 10_000))
        #expect(result.blocks.map(\.kind) == [.change])
        #expect(result.blocks.first?.words.count == 3)
    }

    @Test func multiLineBlockOverTheValveIsADeleteAndAnInsert() {
        let a = Array("alpha one two\nbeta three four\n".utf8)
        let b = Array("alpha one 2\nbeta three 4\n".utf8)
        let limited = TextDiff.diff(a, b, options: DiffOptions(maxRefineTokens: 10))
        #expect(limited.blocks.map(\.kind) == [.delete, .insert])
        let unlimited = TextDiff.diff(a, b, options: DiffOptions(maxRefineTokens: 0))
        #expect(unlimited.blocks.map(\.kind) == [.change])
        #expect(unlimited.blocks.first?.words.count == 2)
    }

    @Test func lineLevelOnlySkipsWordRefinement() {
        let a = Array("same\nold line\nsame too\n".utf8)
        let b = Array("same\nnew line\nsame too\n".utf8)
        let result = TextDiff.diff(a, b, options: DiffOptions(wordRefinement: false))
        #expect(result.blocks.map(\.kind) == [.equal, .delete, .insert, .equal])
        #expect(result.blocks.filter { !$0.words.isEmpty }.isEmpty)
    }

    @Test func minifiedJSONKeepsItsTwentyWordHunks() throws {
        // generated/min_{a,b}.json: about 5 MB of JSON on one line, with 20
        // edits. Absent unless generate.py has run.
        let directory = Corpus.generatedDirectory
        guard let a = try? Data(contentsOf: directory.appending(path: "min_a.json")),
              let b = try? Data(contentsOf: directory.appending(path: "min_b.json")) else {
            print("skipping: Tests/corpus/generated is absent (run Tests/corpus/scripts/generate.py)")
            return
        }
        let result = TextDiff.diff([UInt8](a), [UInt8](b))
        #expect(result.changeCount == 1)
        #expect(result.blocks.map(\.kind) == [.change])
        #expect(result.blocks.first?.words.count == 20)
    }
}
