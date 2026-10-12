// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol
import PrismTestSupport
import Testing
@testable import PrismTool

/// `prism sniff`, and how `prism diff` and `prism merge3` use the text
/// import (encodings, documents, binary refusal).
@Suite struct TextImportCommandTests {

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func prism(_ args: [String]) -> Output {
        let out = CapturedOutput()
        let err = CapturedOutput()
        let status = PrismCommand.run(args, programName: "prism", stdout: out.sink, stderr: err.sink)
        return Output(status: status, stdout: out.text, stderr: err.text)
    }

    static func corpus(_ file: String) -> String {
        Corpus.directory.appending(path: "encodings/\(file)").path(percentEncoded: false)
    }

    // MARK: sniff

    @Test func sniffReportsUTF16WithBOM() {
        let file = Self.corpus("utf16le-bom.txt")
        let result = Self.prism(["sniff", file])
        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout == """
            file: \(file)
            kind: text
            encoding: utf-16le
            bom: yes
            line-endings: lf
            lines: 3
            final-newline: yes
            bytes: 148
            round-trip: yes

            """)
    }

    @Test func sniffJSONHasOneObjectPerFile() {
        let result = Self.prism(["sniff", "--json", Self.corpus("image-png.bin"), Self.corpus("doc.pdf"),
                                 Self.corpus("mixed-crlf.txt")])
        #expect(result.status == 0)
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("\"kind\":\"binary\",\"bytes\":74}"))
        #expect(lines[1].contains("\"kind\":\"document\",\"format\":\"pdf\",\"line-endings\":\"lf\""))
        #expect(lines[2].contains("\"encoding\":\"utf-8\",\"bom\":false,\"line-endings\":\"mixed\",\"lines\":5"))
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
    }

    @Test func sniffSeparatesRecordsWithABlankLine() {
        let result = Self.prism(["sniff", "/dev/null", "/nonexistent/prism-file"])
        #expect(result.status == 0)
        #expect(result.stdout.hasSuffix("round-trip: yes\n\nfile: /nonexistent/prism-file\nkind: missing\n"))
    }

    @Test func sniffClassifiesFolders() {
        let result = Self.prism(["sniff", Corpus.directory.path(percentEncoded: false)])
        #expect(result.stdout.contains("kind: directory\n"))
        #expect(!result.stdout.contains("bytes:"))
    }

    @Test func sniffReportsErrorsAndKeepsGoing() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let file = dir.url.appending(path: "locked.txt")
        try Data("x\n".utf8).write(to: file)
        chmod(file.path(percentEncoded: false), 0)
        defer { chmod(file.path(percentEncoded: false), 0o644) }
        guard getuid() != 0 else { return }
        let result = Self.prism(["sniff", file.path(percentEncoded: false), "/dev/null"])
        #expect(result.status == 2)
        #expect(result.stderr == "prism sniff: \(file.path(percentEncoded: false)): Permission denied\n")
        #expect(result.stdout.contains("file: /dev/null"))
    }

    @Test(arguments: [["sniff", "--bogus", "x"], ["sniff", "-", "-"]])
    func sniffUsageErrors(args: [String]) {
        let result = Self.prism(args)
        #expect(result.status == 2)
        #expect(result.stderr.contains("usage: prism sniff"))
    }

    @Test func sniffHelp() {
        let result = Self.prism(["sniff", "--help"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("usage: prism sniff [--json] FILE ..."))
    }

    @Test func jsonQuoting() {
        #expect(SniffCommand.quote("a\"b\\c\n\u{1}é") == "\"a\\\"b\\\\c\\n\\u0001é\"")
    }

    // MARK: diff and merge3

    @Test(arguments: ["image-png.bin", "archive.zip", "macho.bin"])
    func diffRefusesBinaryFiles(file: String) {
        let path = Self.corpus(file)
        let result = Self.prism(["diff", Self.corpus("utf8.txt"), path])
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr == "prism diff: \(path): binary file; only text files can be compared\n")
    }

    @Test func mergeRefusesBinaryFiles() {
        let png = Self.corpus("image-png.bin")
        let text = Self.corpus("utf8.txt")
        let result = Self.prism(["merge3", text, png, text])
        #expect(result.status == 2)
        #expect(result.stderr == "prism merge3: \(png): binary file; only text files can be compared\n")
    }

    @Test func encodingsAndBOMsDoNotMakeADifference() {
        let utf8 = Self.corpus("utf8.txt")
        for other in ["utf8-bom.txt", "utf16le-bom.txt", "utf16be-bom.txt"] {
            let result = Self.prism(["diff", utf8, Self.corpus(other)])
            #expect(result.status == 0, "\(other)")
            #expect(result.stdout.isEmpty)
        }
        #expect(Self.prism(["diff", Self.corpus("latin1.txt"), Self.corpus("utf16le.txt")]).status == 0)
    }

    @Test func decodedTextIsShownAsUTF8() {
        let result = Self.prism(["diff", Self.corpus("latin1.txt"), Self.corpus("utf8.txt")])
        #expect(result.status == 1)
        #expect(result.stdout.contains("-Café, naïve, façade, Ångström, smörgåsbord.\n"))
        #expect(result.stdout.contains("+Unicode: café, Ελληνικά, 日本語, 한국어.\n"))
    }

    @Test func lineEndingsSurviveDecoding() {
        // Same words, CRLF against LF: different at --ws 0, equal at --ws 1.
        let crlf = Self.corpus("crlf.txt"), lf = Self.corpus("latin1.txt")
        #expect(Self.prism(["diff", crlf, lf]).status == 1)
        #expect(Self.prism(["diff", "--ws", "1", crlf, lf]).status == 0)
    }

    @Test(arguments: ["rtf", "pdf", "docx", "odt", "doc"])
    func documentsCompareByTheirText(format: String) {
        let result = Self.prism(["diff", Self.corpus("doc.\(format).expected"), Self.corpus("doc.\(format)")])
        #expect(result.status == 0, "\(result.stdout)")
    }

    @Test func standardInputIsDecodedToo() throws {
        let file = Self.corpus("utf16be-bom.txt")
        let fd = open(file, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let imported = try TextInput.read("-", standardInput: fd)
        #expect(imported.encoding?.name == "utf-16be")
        #expect(imported.hasBOM)
    }

    @Test func missingFilesAreStillErrorsForDiff() {
        let result = Self.prism(["diff", "/nonexistent/prism-a", Self.corpus("utf8.txt")])
        #expect(result.status == 2)
        #expect(result.stderr == "prism diff: /nonexistent/prism-a: No such file or directory\n")
    }

    @Test func binaryPropertyListsDiffAsXML() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        var paths: [String] = []
        for (name, value) in [("p1.plist", "v"), ("p2.plist", "w")] {
            let url = dir.url.appending(path: name)
            try PropertyListSerialization.data(fromPropertyList: ["k": value], format: .binary, options: 0).write(to: url)
            paths.append(url.path(percentEncoded: false))
        }
        let result = Self.prism(["diff", paths[0], paths[1]])
        #expect(result.status == 1)
        #expect(result.stdout.contains("-\t<string>v</string>\n+\t<string>w</string>\n"))
        #expect(Self.prism(["sniff", paths[0]]).stdout.contains("format: bplist\n"))
    }
}
