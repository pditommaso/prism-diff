// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol
import PrismTestSupport
import Testing
@testable import PrismTool

/// `prism merge3`, run in process against the cases in Tests/corpus/merge.
@Suite struct Merge3CommandTests {

    static func prism(_ args: [String]) -> DiffCommandTests.Output {
        DiffCommandTests.prism(args)
    }

    static var mergeDirectory: URL {
        Corpus.directory.appending(path: "merge", directoryHint: .isDirectory)
    }

    static let caseNames: [String] = {
        let root = mergeDirectory.path(percentEncoded: false)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries.filter { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root + "/" + name, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted()
    }()

    static func file(_ name: String, in caseName: String) -> String {
        mergeDirectory.appending(path: caseName).appending(path: name).path(percentEncoded: false)
    }

    /// The case's extra flags from args.txt, if any.
    static func extraArguments(_ caseName: String) -> [String] {
        guard let text = try? String(contentsOfFile: file("args.txt", in: caseName), encoding: .utf8) else {
            return []
        }
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    @Test func thereAreAtLeastEightCases() {
        #expect(Self.caseNames.count >= 8)
        #expect(Self.caseNames.contains("notes"))
    }

    @Test(arguments: caseNames)
    func jsonEqualsTheExpectedOutput(caseName: String) throws {
        let args = ["merge3"] + Self.extraArguments(caseName) + ["--json"]
            + ["base.txt", "a.txt", "b.txt"].map { Self.file($0, in: caseName) }
        let result = Self.prism(args)
        let expected = try Data(contentsOf: URL(filePath: Self.file("expected.json", in: caseName)))
        #expect(Data(result.stdout.utf8) == expected)
        #expect(result.stderr.isEmpty)

        let object = try #require(try JSONSerialization.jsonObject(with: expected) as? [String: Any])
        let conflicts = try #require(object["conflicts"] as? Int)
        #expect(object["format"] as? String == "prism-merge3")
        #expect(result.status == (conflicts > 0 ? 1 : 0))
        if caseName == "notes" { #expect(conflicts == 1) }
    }

    @Test func summaryWithoutJSON() {
        let result = Self.prism(["merge3"] + ["base.txt", "a.txt", "b.txt"].map { Self.file($0, in: "notes") })
        #expect(result.status == 1)
        #expect(result.stdout == "conflict: A line 2, B line 2; base line 2\n1 difference, 1 conflict\n")
    }

    @Test func summaryOfAnAutomaticMerge() {
        let result = Self.prism(["merge3"] + ["base.txt", "a.txt", "b.txt"].map { Self.file($0, in: "a-only") })
        #expect(result.status == 0)
        #expect(result.stdout.hasPrefix("merged (took a): "))
        #expect(result.stdout.hasSuffix("1 difference, 0 conflicts\n"))
    }

    @Test(arguments: [
        ["merge3"],
        ["merge3", "x", "y"],
        ["merge3", "w", "x", "y", "z"],
        ["merge3", "--ws", "9", "x", "y", "z"],
        ["merge3", "--unified", "x", "y", "z"],
    ])
    func usageErrorsExitTwo(args: [String]) {
        let result = Self.prism(args)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.hasPrefix("prism merge3: "))
        #expect(result.stderr.contains("usage: prism merge3 "))
    }

    @Test func missingInputIsTrouble() {
        let base = Self.file("base.txt", in: "notes")
        let result = Self.prism(["merge3", "--json", base, base + ".missing", base])
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.hasSuffix(".missing: No such file or directory\n"))
    }

    @Test func mergeHasItsOwnHelp() {
        let result = Self.prism(["merge3", "--help"])
        #expect(result.status == 0)
        for text in ["usage: prism merge3 ", "--json", "--ws", "Exit status"] {
            #expect(result.stdout.contains(text))
        }
    }
}
