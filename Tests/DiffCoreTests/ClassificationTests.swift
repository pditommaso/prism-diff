// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Testing

@Suite struct ClassificationTests {
    @Test func blocksAreClassifiedFromTheirRanges() {
        let equal = DiffBlock(kind: .equal, a: 0 ..< 2, b: 0 ..< 2)
        let insert = DiffBlock(kind: .insert, a: 2 ..< 2, b: 2 ..< 4)
        let delete = DiffBlock(kind: .delete, a: 2 ..< 3, b: 4 ..< 4)
        let change = DiffBlock(kind: .change, a: 3 ..< 4, b: 4 ..< 5)
        #expect(!equal.isChange && !equal.isInsert && !equal.isDelete)
        #expect(insert.isInsert && !insert.isChange && !insert.isDelete)
        #expect(delete.isDelete && !delete.isChange && !delete.isInsert)
        #expect(change.isChange && !change.isInsert && !change.isDelete)
    }

    @Test func everyDifferenceInTheSwiftPairHasExactlyOneClass() throws {
        let result = TextDiff.diff(try Fixtures.bytes("text/a.swift"), try Fixtures.bytes("text/b.swift"))
        for block in Fixtures.differences(result) {
            let classes = [block.isChange, block.isInsert, block.isDelete].filter { $0 }.count
            #expect(classes == 1)
            #expect(block.isChange == (block.kind == .change))
            #expect(block.isInsert == (block.kind == .insert))
            #expect(block.isDelete == (block.kind == .delete))
        }
        let kinds = Fixtures.differences(result).flatMap(\.words).map(\.kind)
        #expect(kinds == [.insertOnly, .replace, .insertOnly, .replace, .replace])
    }

    @Test func wordHunkKindFollowsItsRanges() {
        #expect(WordHunk(aLine: 0, bLine: 0, a: 1 ..< 3, b: 1 ..< 4).kind == .replace)
        #expect(WordHunk(aLine: 0, bLine: 0, a: 1 ..< 1, b: 1 ..< 4).kind == .insertOnly)
        #expect(WordHunk(aLine: 0, bLine: 0, a: 1 ..< 3, b: 1 ..< 1).kind == .deleteOnly)
    }
}
