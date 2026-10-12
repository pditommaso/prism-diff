// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
@testable import DiffCore
import Foundation
import PrismTestSupport
import Testing

/// The hand-written cases under Tests/corpus/merge and the identity
/// properties of the three-way merge.
@Suite struct Merge3Tests {

    // MARK: corpus cases

    static var mergeDirectory: URL {
        Corpus.directory.appending(path: "merge", directoryHint: .isDirectory)
    }

    /// Every case directory, sorted by name.
    static let caseNames: [String] = {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: mergeDirectory.path(percentEncoded: false))) ?? []
        return entries.filter { name in
            var isDirectory: ObjCBool = false
            let path = mergeDirectory.appending(path: name).path(percentEncoded: false)
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted()
    }()

    /// Expected conflict count and kinds of the non-equal regions of each
    /// case, worked out by hand from the inputs.
    static let expectations: [String: (conflicts: Int, kinds: [MergeRegionKind], choices: [MergeChoice])] = [
        "a-only": (0, [.auto], [.a]),
        "b-only": (0, [.auto, .auto], [.b, .b]),
        "disjoint": (0, [.auto, .auto], [.a, .b]),
        "same-edit": (0, [], []),
        "overlap-conflict": (1, [.conflict], [.none]),
        "insert-same-point": (1, [.conflict], [.none]),
        "delete-vs-edit": (1, [.conflict], [.none]),
        "notes": (1, [.conflict], [.none]),
        "crlf": (0, [.auto, .auto], [.a, .b]),
        "mixed": (1, [.auto, .auto, .auto, .conflict], [.a, .a, .b, .none]),
        "adjacent-change-insert": (0, [.auto, .auto], [.a, .b]),
        "append-after-closing-line": (0, [.auto, .auto], [.a, .b]),
        "split-by-agreement": (0, [.auto, .auto], [.a, .b]),
    ]

    struct Case {
        var base: [UInt8], a: [UInt8], b: [UInt8]
        var options: DiffOptions
        var directory: URL
    }

    static func load(_ name: String) throws -> Case {
        let directory = mergeDirectory.appending(path: name, directoryHint: .isDirectory)
        func read(_ file: String) throws -> [UInt8] {
            [UInt8](try Data(contentsOf: directory.appending(path: file)))
        }
        var options = DiffOptions()
        // Optional CLI flags for `prism merge3`; only --ws is understood here.
        if let args = try? String(contentsOf: directory.appending(path: "args.txt"), encoding: .utf8) {
            let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
            if let i = words.firstIndex(of: "--ws"), i + 1 < words.count,
               let raw = Int(words[i + 1]), let mode = WhitespaceMode(rawValue: raw) {
                options.whitespace = mode
            }
        }
        return Case(base: try read("base.txt"), a: try read("a.txt"), b: try read("b.txt"),
                    options: options, directory: directory)
    }

    @Test func corpusHasTheRequiredCases() {
        #expect(Self.caseNames.count >= 8)
        #expect(Set(Self.caseNames) == Set(Self.expectations.keys))
    }

    @Test(arguments: caseNames)
    func caseMatchesItsGolden(_ name: String) throws {
        let testCase = try Self.load(name)
        let result = try Merge3.merge(base: testCase.base, a: testCase.a, b: testCase.b, options: testCase.options)
        let golden = Golden.check(result.json, against: "expected.json", in: testCase.directory,
                                  environment: ProcessInfo.processInfo.environment)
        #expect(golden.passed, "\(golden.message)")

        let expected = try #require(Self.expectations[name])
        #expect(result.conflictCount == expected.conflicts)
        #expect(result.unresolvedConflictCount == expected.conflicts)
        #expect(result.differences.map(\.kind) == expected.kinds)
        #expect(result.differences.map(\.choice) == expected.choices)
        Self.checkStructure(result)
    }

    @Test func adjacentChangeAndInsertAreTwoAutomaticRegions() throws {
        // A edits a line, B inserts right after it: the A-B diff has a
        // change next to an insert, and each is decided on its own.
        let c = try Self.load("adjacent-change-insert")
        let result = try Merge3.merge(base: c.base, a: c.a, b: c.b, options: c.options)
        #expect(result.conflictCount == 0)
        #expect(result.differences.count == result.diffAB.changeCount)
        #expect(result.differences.map(\.aRange) == [1 ..< 2, 2 ..< 2])
        #expect(result.differences.map(\.bRange) == [1 ..< 2, 2 ..< 3])
        #expect(String(decoding: result.merged, as: UTF8.self)
                == "title: night walk\nlength_km = 6\nbring a torch\npace = easy\nend\n")
    }

    @Test func editSpanningTwoDiffBlocksStaysOneRegion() throws {
        // B rewrites one base line as two; A rewrites the same line its own
        // way. The A-B diff may split B's two lines over a change and an
        // insert, but both come from one base edit, so they are decided
        // together: one conflict, not a conflict plus an automatic insert.
        let base = Array("p\nkeep\nq\n".utf8)
        let a = Array("p\nkeep it\nq\n".utf8)
        let b = Array("p\nkeep that\nand more\nq\n".utf8)
        let result = try Merge3.merge(base: base, a: a, b: b)
        #expect(result.diffAB.changeCount == 2, "the A-B diff splits B's lines over two blocks")
        #expect(result.conflictCount == 1)
        #expect(result.differences.count == 1)
        #expect(result.differences.first?.bRange == 1 ..< 3)
        // Only B rewrote it: B's two lines are taken together.
        let onlyB = try Merge3.merge(base: base, a: base, b: b)
        #expect(onlyB.merged == b && onlyB.differences.count == 1)
    }

    @Test func conflictChunkIsSplitWhereBothSidesAgree() throws {
        // A rewrites lines 1-2, B lines 2-3, and both rewrite line 2 the
        // same way. In base the edits overlap, but per A-B pair only one
        // side changed: line 1 takes A, line 3 takes B, no conflict.
        let base = "x\ny\nz\nw\n".bytes
        let a = "X\nY\nz\nw\n".bytes
        let b = "x\nY\nZ\nw\n".bytes
        let result = try Merge3.merge(base: base, a: a, b: b)
        #expect(result.conflictCount == 0)
        #expect(result.differences.map(\.choice) == [.a, .b])
        #expect(result.merged == "X\nY\nZ\nw\n".bytes)
        Self.checkStructure(result)
    }

    @Test func refinedChunkKeepsTheRealConflict() throws {
        // As above, but both sides also rewrite line 3 differently: line 1
        // is automatic, line 3 stays a conflict of its own.
        let base = "x\ny\nz\nw\n".bytes
        let a = "X\nY\nz1\nw\n".bytes
        let b = "x\nY\nz2\nw\n".bytes
        let result = try Merge3.merge(base: base, a: a, b: b)
        #expect(result.conflictCount == 1)
        #expect(result.differences.map(\.kind) == [.auto, .conflict])
        #expect(result.differences.last?.aRange == 2 ..< 3)
        Self.checkStructure(result)
    }

    @Test func withoutABaseEachDifferenceIsItsOwnConflict() throws {
        // git passes an empty base for add/add conflicts: the lines both
        // sides have stay common, each difference is a conflict of its own.
        let a = "header\none\ncommon\ntwo\nfooter\n".bytes
        let b = "header\nuno\ncommon\ndos\nfooter\n".bytes
        let result = try Merge3.mergeWithoutBase(a: a, b: b)
        #expect(result.conflictCount == 2)
        #expect(result.differences.map(\.aRange) == [1 ..< 2, 3 ..< 4])
        #expect(result.merged == a, "unresolved conflicts keep A's lines")
        Self.checkStructure(result, strict: false)
        // An insertion only one side made is still a conflict without a base.
        let only = try Merge3.mergeWithoutBase(a: "x\ny\n".bytes, b: "x\nnew\ny\n".bytes)
        #expect(only.conflictCount == 1 && only.differences.count == 1)
    }

    @Test func bothInsertingAtOnePointSplitsWhereTheyAgree() throws {
        let base = "top\nbottom\n".bytes
        let a = "top\nmine\nshared\nbottom\n".bytes
        let b = "top\nshared\ntheirs\nbottom\n".bytes
        let result = try Merge3.merge(base: base, a: a, b: b)
        #expect(result.conflictCount == 0)
        #expect(result.merged == "top\nmine\nshared\ntheirs\nbottom\n".bytes)
        Self.checkStructure(result)
    }

    @Test func emptyBaseAgainstPropertyInputsIsWellFormed() throws {
        var rng = SplitMix64(seed: 99)
        for iteration in 0 ..< Self.propertyIterations {
            let (_, a, b) = Self.randomTriple(&rng, iteration: iteration)
            Self.checkStructure(try Merge3.merge(base: [], a: a, b: b))
            let noBase = try Merge3.mergeWithoutBase(a: a, b: b)
            Self.checkStructure(noBase, strict: false)
            #expect(noBase.regions.allSatisfy { $0.kind != .auto })
        }
    }

    @Test func resettingAnAutomaticRegionTakesNothing() throws {
        let c = try Self.load("disjoint")
        let result = try Merge3.merge(base: c.base, a: c.a, b: c.b)
        let index = try #require(result.regions.firstIndex { $0.kind == .auto })
        let reset = result.applying(choice: .none, to: index)
        #expect(reset.regions[index].mergedRange.isEmpty)
        #expect(reset.unresolvedConflictCount == 0)
        Self.checkStructure(reset)
    }

    @Test func notesCaseIsOneConflictThatKeepsALinesUntilResolved() throws {
        let testCase = try Self.load("notes")
        let result = try Merge3.merge(base: testCase.base, a: testCase.a, b: testCase.b)
        #expect(result.conflictCount == 1)
        #expect(result.unresolvedConflictCount == 1)
        // The merged text starts as A with every automatic choice applied.
        #expect(String(decoding: result.merged, as: UTF8.self) == "line1\nline2 main\nline3\n")
        let conflict = try #require(result.differences.first)
        #expect(conflict.aRange == 1 ..< 2 && conflict.bRange == 1 ..< 2)
        #expect(conflict.baseRange == 1 ..< 2)
        #expect(conflict.mergedRange == 1 ..< 2)
        #expect(conflict.isConflict && conflict.isUnresolved)
    }

    @Test func autoMergesTakeBothSidesEdits() throws {
        let disjoint = try Self.load("disjoint")
        let merged = try Merge3.merge(base: disjoint.base, a: disjoint.a, b: disjoint.b).merged
        let text = String(decoding: merged, as: UTF8.self)
        #expect(text.contains("into a clean directory") && text.contains("and push the tag"))

        let crlf = try Self.load("crlf")
        // Line endings count at .exact, so A changed every line: a conflict.
        #expect(try Merge3.merge(base: crlf.base, a: crlf.a, b: crlf.b).conflictCount == 1)
        let relaxed = try Merge3.merge(base: crlf.base, a: crlf.a, b: crlf.b, options: crlf.options)
        let relaxedText = String(decoding: relaxed.merged, as: UTF8.self)
        #expect(relaxedText.contains("the dog demands his share,\r\n"))
        #expect(relaxedText.contains("and somewhere in a pocket lost\n"))
    }

    // MARK: applying choices

    @Test func applyingChoicesRebuildsTheMergedText() throws {
        let testCase = try Self.load("notes")
        let result = try Merge3.merge(base: testCase.base, a: testCase.a, b: testCase.b)
        let index = try #require(result.regions.firstIndex { $0.kind == .conflict })
        let expected: [MergeChoice: String] = [
            .none: "line1\nline2 main\nline3\n",
            .a: "line1\nline2 main\nline3\n",
            .b: "line1\nline2 feature\nline3\n",
            .aThenB: "line1\nline2 main\nline2 feature\nline3\n",
            .bThenA: "line1\nline2 feature\nline2 main\nline3\n",
        ]
        for choice in MergeChoice.allCases {
            let applied = result.applying(choice: choice, to: index)
            #expect(String(decoding: applied.merged, as: UTF8.self) == expected[choice])
            #expect(applied.conflictCount == 1)
            #expect(applied.unresolvedConflictCount == (choice == .none ? 1 : 0))
            #expect(applied.regions[index].choice == choice)
            #expect(applied.regions[index].autoChoice == .none)
            Self.checkStructure(applied)
        }
        // Resetting brings back the original.
        #expect(result.applying(choice: .b, to: index).applying(choice: .none, to: index) == result)
    }

    @Test func choiceCodesAreStable() {
        #expect(MergeChoice.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
        #expect(MergeChoice.allCases.map(\.name) == ["none", "a", "b", "aThenB", "bThenA"])
    }

    @Test func linesWithoutTerminatorDoNotRunTogether() throws {
        let result = try Merge3.merge(base: "x\nold".bytes, a: "x\nmine".bytes, b: "x\ntheirs".bytes)
        let index = try #require(result.regions.firstIndex { $0.kind == .conflict })
        let both = result.applying(choice: .aThenB, to: index)
        #expect(String(decoding: both.merged, as: UTF8.self) == "x\nmine\ntheirs")
        #expect(both.mergedLines.count == 3)
        Self.checkStructure(both)
    }

    // MARK: edge cases

    @Test func emptyInputs() throws {
        let empty = try Merge3.merge(base: [], a: [], b: [])
        #expect(empty.regions.isEmpty && empty.merged.isEmpty && empty.conflictCount == 0)

        let addedByA = try Merge3.merge(base: [], a: "new\n".bytes, b: [])
        #expect(addedByA.merged == "new\n".bytes && addedByA.conflictCount == 0)

        let bothAdded = try Merge3.merge(base: [], a: "one\n".bytes, b: "two\n".bytes)
        #expect(bothAdded.conflictCount == 1 && bothAdded.merged == "one\n".bytes)

        let deletedByB = try Merge3.merge(base: "gone\n".bytes, a: "gone\n".bytes, b: [])
        #expect(deletedByB.merged.isEmpty && deletedByB.conflictCount == 0)
    }

    @Test func deletionAtARegionEdgeIsNotLost() throws {
        // A deletes "figs" next to the line B edits. Taking B's side would
        // bring the deleted line back, so this must be a conflict.
        let base = "apples\nplums\nfigs\ndates\n".bytes
        let a = "apples\nplums\ndates\n".bytes
        let b = "apples\nplums 7\nfigs\ndates\n".bytes
        let result = try Merge3.merge(base: base, a: a, b: b)
        #expect(result.conflictCount == 1)
    }

    @Test func editOverlappingTheOtherSidesDeletionConflicts() throws {
        // Both delete "two"; B also edits the next line. B's base-B edit
        // covers "two" and "three" while A's region covers only "three", so
        // the edits overlap in base: a conflict, as `git merge-file` reports.
        let base = "one\ntwo\nthree\n".bytes
        let a = "one\nthree\n".bytes
        let b = "one\nTHREE\n".bytes
        let result = try Merge3.merge(base: base, a: a, b: b)
        #expect(result.conflictCount == 1)
        let index = try #require(result.regions.firstIndex { $0.kind == .conflict })
        #expect(result.applying(choice: .b, to: index).merged == b)
    }

    @Test func trailingBlankLineAddedByBIsKept() throws {
        // A edits the first line, B adds a blank line at the end. The A-B
        // diff places B's blank line one line earlier than the base-B diff
        // does (both are right: the lines are equal); that must not make A
        // look like it changed B's region and drop B's line.
        let base = "title\n\nbody\n\n".bytes
        let a = "title v2\n\nbody\n\n".bytes
        let b = "title\n\nbody\n\n\n".bytes
        let result = try Merge3.merge(base: base, a: a, b: b)
        #expect(result.conflictCount == 0)
        #expect(result.merged == "title v2\n\nbody\n\n\n".bytes)
        #expect(result.differences.map(\.choice) == [.a, .b])
        Self.checkStructure(result)
    }

    @Test func functionAppendedAfterAClosingLineIsNotAConflict() throws {
        // A edits the header, B appends a function after the last "}". The
        // A-B diff pairs A's "}" with B's second one, so B's insertion seems
        // to contain base's "}"; in base coordinates the edits are far apart.
        let c = try Self.load("append-after-closing-line")
        let result = try Merge3.merge(base: c.base, a: c.a, b: c.b)
        #expect(result.conflictCount == 0)
        #expect(String(decoding: result.merged, as: UTF8.self)
                == "// header v2\nfunc a() {\n    one()\n}\n\nfunc b() {\n    two()\n}\n")
    }

    @Test func sameEditInsideAConflictChunkIsEqualUnderTheWhitespaceMode() throws {
        // Both sides rewrite the line the same way, but B ends it with CRLF.
        let base = "x\nold\ny\n".bytes
        let a = "x\nnew\ny\n".bytes
        let b = "x\nnew\r\ny\n".bytes
        #expect(try Merge3.merge(base: base, a: a, b: b).conflictCount == 1)
        let relaxed = try Merge3.merge(base: base, a: a, b: b, options: DiffOptions(whitespace: .ignoreLineEndings))
        #expect(relaxed.conflictCount == 0 && relaxed.differences.isEmpty && relaxed.merged == a)
    }

    @Test func mergesOfTwoGigabytesOrMoreAreRefused() throws {
        // Resolving every conflict as A then B can hold all of A and all
        // of B, so their sizes together must stay under 2 GiB.
        let limit = Int(Int32.max)
        try Merge3.checkSize(base: 0, limit / 2, limit / 2 - 2)
        #expect(throws: DiffError.tooLarge) { try Merge3.checkSize(base: 0, limit / 2, limit / 2 - 1) }
        #expect(throws: DiffError.tooLarge) { try Merge3.checkSize(base: 0, 1_100 << 20, 1_100 << 20) }
        // The base is diffed on its own, so it has the engine's own limit.
        try Merge3.checkSize(base: limit - 1, 10, 10)
        #expect(throws: DiffError.tooLarge) { try Merge3.checkSize(base: limit, 10, 10) }
    }

    @Test func cancelledTokenStopsTheMerge() {
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: DiffError.cancelled) {
            _ = try Merge3.merge(base: "a\n".bytes, a: "b\n".bytes, b: "c\n".bytes,
                                 options: DiffOptions(cancellation: flag))
        }
    }

    @Test func parallelAndSerialAgree() throws {
        // Big enough to take the concurrent path.
        var rng = SplitMix64(seed: 7)
        let lines = CaseGenerator.randomLines(6000, &rng)
        let base = CaseGenerator.join(lines, eol: "\n", finalNewline: true)
        let a = CaseGenerator.join(CaseGenerator.mutate(lines, &rng), eol: "\n", finalNewline: true)
        let b = CaseGenerator.join(CaseGenerator.mutate(lines, &rng), eol: "\n", finalNewline: true)
        #expect(base.count + a.count + b.count >= 64 << 10)
        let parallel = try Merge3.merge(base: base, a: a, b: b)
        let serial = try Merge3.merge(base: base, a: a, b: b, options: DiffOptions(parallel: false))
        #expect(parallel.regions == serial.regions && parallel.merged == serial.merged)
    }

    // MARK: properties

    static let propertyIterations: Int = {
        if let text = ProcessInfo.processInfo.environment["PRISM_PROPERTY_ITERATIONS"],
           let value = Int(text), value > 0 {
            return value
        }
        return 300
    }()

    /// Random base, A and B: base and two independent mutations of it.
    static func randomTriple(_ rng: inout SplitMix64, iteration: Int) -> (base: [UInt8], a: [UInt8], b: [UInt8]) {
        let lines = CaseGenerator.randomLines(Int.random(in: 0 ... 120, using: &rng), &rng)
        let final = iteration % 5 != 0
        let base = CaseGenerator.join(lines, eol: "\n", finalNewline: final)
        let a = CaseGenerator.join(CaseGenerator.mutate(lines, &rng), eol: "\n", finalNewline: final)
        let b = CaseGenerator.join(CaseGenerator.mutate(lines, &rng), eol: iteration % 9 == 0 ? "\r\n" : "\n",
                                   finalNewline: iteration % 7 != 0)
        return (base, a, b)
    }

    @Test func identityProperties() throws {
        var rng = SplitMix64(seed: 2026)
        for iteration in 0 ..< Self.propertyIterations {
            let (base, a, b) = Self.randomTriple(&rng, iteration: iteration)

            // base == A: B's edits are all taken.
            let takeB = try Merge3.merge(base: base, a: base, b: b)
            #expect(takeB.conflictCount == 0, "base == A, iteration \(iteration)")
            #expect(takeB.merged == b, "base == A, iteration \(iteration)")

            // base == B: A's edits are all taken.
            let takeA = try Merge3.merge(base: base, a: a, b: base)
            #expect(takeA.conflictCount == 0, "base == B, iteration \(iteration)")
            #expect(takeA.merged == a, "base == B, iteration \(iteration)")

            // A == B: nothing to decide.
            let same = try Merge3.merge(base: base, a: a, b: a)
            #expect(same.conflictCount == 0 && same.differences.isEmpty, "A == B, iteration \(iteration)")
            #expect(same.merged == a, "A == B, iteration \(iteration)")

            for result in [takeB, takeA, same] { Self.checkStructure(result) }
            if takeB.conflictCount != 0 || takeA.conflictCount != 0 || takeB.merged != b || takeA.merged != a {
                return  // one report per run is enough
            }
        }
    }

    @Test func identityPropertiesIgnoringLineEndings() throws {
        var rng = SplitMix64(seed: 77)
        let options = DiffOptions(whitespace: .ignoreLineEndings)
        for iteration in 0 ..< Self.propertyIterations / 3 {
            let (base, a, b) = Self.randomTriple(&rng, iteration: iteration)
            #expect(try Merge3.merge(base: base, a: base, b: b, options: options).conflictCount == 0)
            #expect(try Merge3.merge(base: base, a: a, b: base, options: options).conflictCount == 0)
            #expect(try Merge3.merge(base: base, a: a, b: a, options: options).differences.isEmpty)
        }
    }

    @Test func randomMergesAreWellFormed() throws {
        var rng = SplitMix64(seed: 4242)
        for iteration in 0 ..< Self.propertyIterations {
            let (base, a, b) = Self.randomTriple(&rng, iteration: iteration)
            let result = try Merge3.merge(base: base, a: a, b: b)
            Self.checkStructure(result)
            // Resolving every conflict leaves nothing unresolved.
            var resolved = result
            for index in resolved.regions.indices where resolved.regions[index].kind == .conflict {
                resolved = resolved.applying(choice: .aThenB, to: index)
            }
            #expect(resolved.unresolvedConflictCount == 0)
            #expect(resolved.conflictCount == result.conflictCount)
            Self.checkStructure(resolved)
        }
    }

    @Test func randomMergesWithForcedHeuristicsAreWellFormed() throws {
        // Cost cap at its minimum and pre-pairing everywhere, as in the
        // forced-heuristics property pass: the diffs give up on minimality,
        // which must still never produce a malformed merge.
        var rng = SplitMix64(seed: 9001)
        let options = DiffOptions(myersMinCost: 1, prePairBytes: 1)
        for iteration in 0 ..< Self.propertyIterations {
            let (base, a, b) = Self.randomTriple(&rng, iteration: iteration)
            let result = try Merge3.merge(base: base, a: a, b: b, options: options)
            Self.checkStructure(result, strict: false)
            #expect(try Merge3.merge(base: base, a: base, b: b, options: options).merged == b)
            #expect(try Merge3.merge(base: base, a: a, b: base, options: options).merged == a)
        }
    }

    /// Lines with many repeats (blank lines, braces), so that the diffs
    /// meet plenty of equally good placements ("sliders").
    static let repetitiveLines = ["", "", "}", "}", "{", "end", "x", "return", "  }", "foo()"]

    /// 0 to 8 random edits drawn from `repetitiveLines`.
    static func repetitiveMutation(_ lines: [String], _ rng: inout SplitMix64) -> [String] {
        var out = lines
        for _ in 0 ..< Int.random(in: 0 ... 8, using: &rng) {
            let i = out.isEmpty ? 0 : Int.random(in: 0 ..< out.count, using: &rng)
            let line = repetitiveLines.randomElement(using: &rng)!
            switch Int.random(in: 0 ..< 4, using: &rng) {
            case 0: out.insert(line, at: min(i + Int.random(in: 0 ... 1, using: &rng), out.count))
            case 1: if !out.isEmpty { out.remove(at: i) }
            case 2: if !out.isEmpty { out[i] = line + " edited" }
            default: if !out.isEmpty { out.insert(out[i], at: i) }
            }
        }
        return out
    }

    @Test(arguments: [false, true])
    func disjointEditsAroundUniqueAnchorsMergeExactly(_ aEditsTop: Bool) throws {
        // One side edits only above three unique anchor lines, the other
        // only below them, so the right merge is unambiguous: the first
        // side's top, the anchors and the second side's bottom, with no
        // conflict. Repeated lines make the three diffs place ambiguous
        // insertions and deletions differently.
        var rng = SplitMix64(seed: aEditsTop ? 31 : 32)
        for iteration in 0 ..< Self.propertyIterations * 5 {
            func random() -> [String] {
                (0 ..< Int.random(in: 0 ... 12, using: &rng)).map { _ in
                    Self.repetitiveLines.randomElement(using: &rng)!
                }
            }
            let top = random(), bottom = random()
            let anchors = (1 ... 3).map { "=== anchor \($0) ===" }
            let editedTop = Self.repetitiveMutation(top, &rng), editedBottom = Self.repetitiveMutation(bottom, &rng)
            let join = { (lines: [String]) in CaseGenerator.join(lines, eol: "\n", finalNewline: true) }
            let base = join(top + anchors + bottom)
            let topSide = join(editedTop + anchors + bottom), bottomSide = join(top + anchors + editedBottom)
            let (a, b) = aEditsTop ? (topSide, bottomSide) : (bottomSide, topSide)
            let expected = join(editedTop + anchors + editedBottom)
            let result = try Merge3.merge(base: base, a: a, b: b)
            #expect(result.conflictCount == 0, "iteration \(iteration)")
            #expect(result.merged == expected, "iteration \(iteration)")
            Self.checkStructure(result)
            if result.conflictCount != 0 || result.merged != expected { return }
        }
    }

    @Test func randomRepetitiveMergesKeepEveryChangedSidesEdit() throws {
        // Both sides edit anywhere, with many repeated lines: every region
        // must still be decided by content (checked in `checkStructure`).
        var rng = SplitMix64(seed: 515)
        for _ in 0 ..< Self.propertyIterations * 3 {
            let lines = (0 ..< Int.random(in: 0 ... 30, using: &rng)).map { _ in
                Self.repetitiveLines.randomElement(using: &rng)!
            }
            let join = { (lines: [String]) in CaseGenerator.join(lines, eol: "\n", finalNewline: true) }
            let base = join(lines)
            let a = join(Self.repetitiveMutation(lines, &rng)), b = join(Self.repetitiveMutation(lines, &rng))
            Self.checkStructure(try Merge3.merge(base: base, a: a, b: b))
            Self.checkStructure(try Merge3.merge(base: base, a: a, b: b, options: DiffOptions(myersMinCost: 1, prePairBytes: 1)),
                                strict: false)
        }
    }

    // MARK: helpers

    /// The bytes of lines `range` of `text`.
    static func slice(_ text: [UInt8], _ index: LineIndex, _ range: Range<Int>) -> ArraySlice<UInt8> {
        range.isEmpty ? [] : text[index.range(range.lowerBound).lowerBound ..< index.range(range.upperBound - 1).upperBound]
    }

    /// Regions are ordered and tile A, B and the merged text; the merged text
    /// is the concatenation of what each region's choice takes; counts agree.
    ///
    /// At `.exact`, regions are also checked against the content they were
    /// decided by. `strict` adds that a side taken automatically, or both
    /// sides of a conflict, really differ from base there; that needs
    /// minimal base diffs (forced heuristics may delete and re-insert the
    /// same line).
    static func checkStructure(_ result: Merge3Result, strict: Bool = true,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let linesA = result.diffAB.linesA, linesB = result.diffAB.linesB, linesBase = result.diffBaseB.linesA
        var a = 0, b = 0, m = 0, baseLine = 0
        var expectedLines = 0
        for region in result.regions {
            #expect(region.aRange.lowerBound == a && region.bRange.lowerBound == b
                    && region.mergedRange.lowerBound == m, sourceLocation: sourceLocation)
            a = region.aRange.upperBound
            b = region.bRange.upperBound
            m = region.mergedRange.upperBound
            if region.kind == .equal {
                #expect(region.choice == .none && region.aRange.count == region.bRange.count,
                        sourceLocation: sourceLocation)
            }
            let taken: Int = switch region.kind == .equal || region.isUnresolved ? MergeChoice.a : region.choice {
            case .none: 0
            case .a: region.aRange.count
            case .b: region.bRange.count
            case .aThenB, .bThenA: region.aRange.count + region.bRange.count
            }
            #expect(region.mergedRange.count == taken, sourceLocation: sourceLocation)
            expectedLines += taken
            #expect(region.baseRange.lowerBound == baseLine, sourceLocation: sourceLocation)
            baseLine = region.baseRange.upperBound
            if result.whitespace == .exact {
                // Decided by content: an automatic region takes the side
                // that differs from base while the other is base's text, a
                // conflict has both sides differing from base and from each
                // other, and an equal region has the same text on both.
                let x = slice(result.a, linesA, region.aRange), y = slice(result.b, linesB, region.bRange)
                let o = slice(result.base, linesBase, region.baseRange)
                let ok = switch (region.kind, region.autoChoice) {
                case (.equal, _): x.elementsEqual(y)
                case (.auto, .a): y.elementsEqual(o) && !(strict && x.elementsEqual(o))
                case (.auto, .b): x.elementsEqual(o) && !(strict && y.elementsEqual(o))
                case (.conflict, _): !x.elementsEqual(y) && !(strict && (x.elementsEqual(o) || y.elementsEqual(o)))
                default: false
                }
                #expect(ok, "\(region)", sourceLocation: sourceLocation)
            }
        }
        #expect(a == linesA.count && b == linesB.count && baseLine == linesBase.count, sourceLocation: sourceLocation)
        #expect(result.mergedLines.count == expectedLines, sourceLocation: sourceLocation)
        #expect(result.conflictCount == result.regions.filter(\.isConflict).count, sourceLocation: sourceLocation)
        #expect(result.unresolvedConflictCount == result.regions.filter(\.isUnresolved).count,
                sourceLocation: sourceLocation)
        // Neighbouring regions are never both equal: they would be one.
        for (x, y) in zip(result.regions, result.regions.dropFirst()) {
            #expect(x.kind != .equal || y.kind != .equal, sourceLocation: sourceLocation)
        }
    }
}
