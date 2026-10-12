// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import Foundation
import PrismTestSupport
import Testing
@testable import PrismApp

private func load(_ name: String) throws -> LoadedText {
    try UTF8TextSource().load(Corpus.fixture("text/\(name)"))
}

private func model(_ a: String, _ b: String, whitespace: WhitespaceMode = .exact) throws -> ComparisonModel {
    try ComparisonModel.build(a: load(a), b: load(b), whitespace: whitespace)
}

private func text(_ string: String) -> LoadedText { UTF8TextSource.decode(Array(string.utf8)) }

/// Every unchanged line sits on the same row as its counterpart.
private func expectEqualLinesAligned(_ model: ComparisonModel) {
    let layout = model.layout
    var checked = 0
    for (index, block) in layout.blocks.enumerated() where block.kind == .equal {
        #expect(block.a.count == block.b.count)
        for offset in 0 ..< block.a.count {
            let rowA = layout.row(ofLine: block.a.lowerBound + offset, side: .a)
            let rowB = layout.row(ofLine: block.b.lowerBound + offset, side: .b)
            if rowA != rowB || rowA != layout.blockStart[index] + offset {
                Issue.record("line A \(block.a.lowerBound + offset) on row \(String(describing: rowA)), B on \(String(describing: rowB))")
                return
            }
            checked += 1
        }
    }
    #expect(checked > 0)
}

@Test func smallPairHasEightChangesAndTheExpectedSpacers() throws {
    let model = try model("a.swift", "b.swift")
    let layout = model.layout
    #expect(model.changeCount == 8)
    #expect(layout.changes.count == 8)
    // import OSLog: an insert, padded on A right after line 1.
    #expect(layout.content(atRow: 0, side: .a) == .line(0, block: 0))
    guard case let .spacer(block, top, bottom) = layout.content(atRow: 1, side: .a) else {
        Issue.record("row 1 of A is not padding")
        return
    }
    #expect(layout.blocks[block].isInsert && top && bottom)
    #expect(layout.content(atRow: 1, side: .b) == .line(1, block: block))
    // var language: an insert after the excited change, padded on A.
    guard case let .line(bLine, languageBlock) = layout.content(atRow: 7, side: .b),
          case .spacer = layout.content(atRow: 7, side: .a) else {
        Issue.record("row 7 is not the language insert")
        return
    }
    #expect(bLine == 7 && layout.blocks[languageBlock].isInsert)
    // The last two lines of A are deleted: two rows of padding on B.
    let last = layout.trailerRow
    guard case let .spacer(deleted, firstTop, firstBottom) = layout.content(atRow: last - 2, side: .b),
          case let .spacer(_, secondTop, secondBottom) = layout.content(atRow: last - 1, side: .b) else {
        Issue.record("the deletion has no padding on B")
        return
    }
    #expect(layout.blocks[deleted].isDelete)
    #expect(firstTop && !firstBottom && !secondTop && secondBottom)
    #expect(layout.content(atRow: last - 1, side: .a) == .line(20, block: deleted))
    // Both files end with a newline: line 22 is the empty trailer on each side.
    #expect(layout.content(atRow: last, side: .a) == .trailer(lineNumber: 22))
    #expect(layout.content(atRow: last, side: .b) == .trailer(lineNumber: 22))
    expectEqualLinesAligned(model)
}

@Test func wordHighlightsLandOnTheChangedTokens() throws {
    let model = try model("a.swift", "b.swift")
    // A line 6 "    var excited: Bool = false", B line 7 "... = true".
    let a = try #require(model.a.words[5]?.first)
    let b = try #require(model.b.words[6]?.first)
    let lineA = Array(model.a.text(ofLine: 5).utf8), lineB = Array(model.b.text(ofLine: 6).utf8)
    #expect(String(decoding: lineA[a], as: UTF8.self) == "false")
    #expect(String(decoding: lineB[b], as: UTF8.self) == "true")
}

@Test func changesAreFoundByRowAndBlock() throws {
    let layout = try model("a.swift", "b.swift").layout
    for (change, block) in layout.changes.enumerated() {
        #expect(layout.change(ofBlock: block) == change)
        for row in layout.rows(ofBlock: block) {
            #expect(layout.change(atRow: row) == change)
        }
    }
    #expect(layout.change(atRow: 0) == nil)
    #expect(layout.change(atRow: layout.trailerRow) == nil)
    #expect(layout.block(atRow: -1) == nil)
    #expect(layout.block(atRow: layout.rowCount + 5) == nil)
}

@Test func bigPairStaysAlignedEverywhere() throws {
    let model = try model("big_a.txt", "big_b.txt")
    #expect(model.changeCount == 944)
    #expect(model.a.lineCount == 100_000)
    #expect(model.b.lineCount == 100_099)
    // Every row holds a line or padding on each side, never two lines.
    #expect(model.layout.rowCount - 1 >= max(model.a.lineCount, model.b.lineCount))
    expectEqualLinesAligned(model)
    // Change 473 (the jump target of the acceptance check).
    let rows = model.layout.rows(ofChange: 472)
    guard case let .line(lineA, _) = model.layout.content(atRow: rows.lowerBound, side: .a),
          case let .line(lineB, _) = model.layout.content(atRow: rows.lowerBound, side: .b) else {
        Issue.record("change 473 is not a change of lines on both sides")
        return
    }
    #expect(model.a.text(ofLine: lineA).hasPrefix("line 51895:"))
    #expect(model.b.text(ofLine: lineB).hasPrefix("line 51895:"))
}

@Test func emptyAndIdenticalInputs() throws {
    let empty = try ComparisonModel.build(a: text(""), b: text(""), whitespace: .exact)
    #expect(empty.changeCount == 0)
    #expect(empty.layout.rowCount == 1)
    #expect(empty.layout.content(atRow: 0, side: .a) == .trailer(lineNumber: 1))

    let same = try ComparisonModel.build(a: text("x\ny"), b: text("x\ny"), whitespace: .exact)
    #expect(same.changeCount == 0)
    #expect(same.layout.content(atRow: 2, side: .b) == .trailer(lineNumber: nil))

    let added = try ComparisonModel.build(a: text(""), b: text("one\ntwo\n"), whitespace: .exact)
    #expect(added.changeCount == 1)
    #expect(added.layout.content(atRow: 0, side: .a) == .spacer(block: 0, top: true, bottom: false))
    #expect(added.layout.content(atRow: 1, side: .a) == .spacer(block: 0, top: false, bottom: true))
}

@Test func ignoringWhitespaceHidesIndentationChanges() throws {
    let exact = try model("a.swift", "b.swift")
    let relaxed = try model("a.swift", "b.swift", whitespace: .ignoreEdgeWhitespace)
    #expect(relaxed.changeCount == exact.changeCount - 1)
}

@Test func lineTextDropsTerminatorsAndMapsColumnsToUTF16() throws {
    let model = try ComparisonModel.build(a: text("caf\u{E9} \u{1F600} x\r\nnext"), b: text("x"), whitespace: .exact)
    let side = model.a
    #expect(side.text(ofLine: 0) == "caf\u{E9} \u{1F600} x")
    #expect(side.hasTerminator(0))
    #expect(!side.hasTerminator(1))
    // "café " is 6 bytes and 5 UTF-16 units; the emoji is 4 bytes, 2 units.
    #expect(side.utf16Offset(line: 0, column: 6) == 5)
    #expect(side.utf16Offset(line: 0, column: 10) == 7)
    #expect(side.utf16Offset(line: 0, column: 999) == 9)
}

@Test func maxColumnsExpandsTabsAndCountsWideCharacters() {
    #expect(ComparisonSide.maxColumns(Array("ab\n\tc\nxyz".utf8)) == 5)
    #expect(ComparisonSide.maxColumns(Array("\u{65E5}\u{672C}".utf8)) == 4)
    #expect(ComparisonSide.maxColumns([]) == 0)
}

@Test func utf8SourceRepairsInvalidInputAndDropsTheMark() throws {
    let valid = UTF8TextSource.decode(Array("h\u{E9}llo".utf8))
    #expect(!valid.isLossy && valid.encodingName == "UTF-8")
    let marked = UTF8TextSource.decode([0xEF, 0xBB, 0xBF] + Array("hi".utf8))
    #expect(marked.bytes == Array("hi".utf8))
    let broken = UTF8TextSource.decode([0x61, 0xFF, 0x62])
    #expect(broken.isLossy)
    #expect(String(decoding: broken.bytes, as: UTF8.self) == "a\u{FFFD}b")
    #expect(throws: (any Error).self) { try UTF8TextSource().load(URL(filePath: "/nonexistent/prism-test")) }
}

@Test func launchArgumentsSkipSystemOptions() {
    let request = LaunchRequest.parse(["Prism", "-psn_0_123", "-NSQuitAlwaysKeepsWindows", "NO",
                                       "--change", "473", "--no-about", "a.txt", "b.txt"])
    #expect(request.paths == ["a.txt", "b.txt"])
    #expect(request.initialChange == 473)
    #expect(LaunchRequest.parse(["Prism"]) == LaunchRequest())
}
