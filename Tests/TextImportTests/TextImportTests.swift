// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismTestSupport
import Testing
@testable import TextImport

/// The corpus in Tests/corpus/encodings and its expected.tsv.
enum EncodingCorpus {
    static let directory = Corpus.directory.appending(path: "encodings", directoryHint: .isDirectory)

    struct Row: Sendable, CustomStringConvertible {
        let file: String, kind: String, encodingOrFormat: String, bom: String, lineEndings: String
        var description: String { file }
    }

    static let rows: [Row] = {
        let url = directory.appending(path: "expected.tsv")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let f = line.split(separator: "\t").map(String.init)
            return Row(file: f[0], kind: f[1], encodingOrFormat: f[2], bom: f[3], lineEndings: f[4])
        }
    }()

    static func url(_ file: String) -> URL { directory.appending(path: file) }

    static func bytes(_ file: String) throws -> [UInt8] { Array(try Data(contentsOf: url(file))) }

    /// Detection with a fixed language hint, so results do not depend on
    /// the locale of the machine running the tests.
    static let options = TextImport.Options(likelyLanguage: "en")
}

@Suite struct CorpusTests {
    @Test func corpusIsComplete() {
        #expect(EncodingCorpus.rows.count >= 21)
    }

    @Test(arguments: EncodingCorpus.rows)
    func classification(row: EncodingCorpus.Row) throws {
        let imported = try TextImport.load(EncodingCorpus.url(row.file), options: EncodingCorpus.options)
        #expect(imported.kind.rawValue == row.kind)
        switch imported.kind {
        case .text:
            #expect(imported.encoding?.name == row.encodingOrFormat)
            #expect(imported.hasBOM == (row.bom == "yes"))
            #expect(imported.lineEndings.style.rawValue == row.lineEndings)
        case .document:
            #expect(imported.documentFormat?.rawValue == row.encodingOrFormat)
            #expect(imported.lineEndings.style.rawValue == row.lineEndings)
        default:
            #expect(imported.utf8.isEmpty)
            #expect(imported.encoding == nil)
        }
    }

    @Test(arguments: EncodingCorpus.rows.filter { $0.kind == "text" })
    func decodeThenEncodeIsByteIdentical(row: EncodingCorpus.Row) throws {
        let original = try EncodingCorpus.bytes(row.file)
        let imported = try TextImport.load(EncodingCorpus.url(row.file), options: EncodingCorpus.options)
        #expect(imported.roundTrips)
        #expect(imported.encoded() == original)
        #expect(imported.byteCount == original.count)
    }

    @Test(arguments: EncodingCorpus.rows.filter { $0.kind == "document" })
    func documentsGiveTheExpectedText(row: EncodingCorpus.Row) throws {
        let expected = try String(contentsOf: EncodingCorpus.url(row.file + ".expected"), encoding: .utf8)
        let imported = try TextImport.load(EncodingCorpus.url(row.file))
        #expect(imported.string == expected)
        #expect(imported.encoded() == nil)
        #expect(!imported.roundTrips)
    }

    @Test func decodedTextIsTheSameWhateverTheEncoding() throws {
        let reference = try TextImport.load(EncodingCorpus.url("utf8.txt")).string
        for file in ["utf8-bom.txt", "utf16le-bom.txt", "utf16be-bom.txt"] {
            #expect(try TextImport.load(EncodingCorpus.url(file)).string == reference)
        }
        let latin = try TextImport.load(EncodingCorpus.url("latin1.txt"), options: EncodingCorpus.options).string
        #expect(latin.contains("Café, naïve, façade, Ångström"))
        #expect(try TextImport.load(EncodingCorpus.url("utf16le.txt")).string == latin)
        let japanese = try TextImport.load(EncodingCorpus.url("shift-jis.txt"), options: EncodingCorpus.options)
        #expect(japanese.string.hasPrefix("日本語のテキストです。\r\n"))
    }

    @Test func lineEndingCounts() throws {
        let mixed = try TextImport.load(EncodingCorpus.url("mixed-crlf.txt")).lineEndings
        #expect(mixed == LineEndings(lf: 2, crlf: 2, cr: 1, hasFinalNewline: true))
        #expect(mixed.lineCount(byteCount: 58) == 5)
        let open = try TextImport.load(EncodingCorpus.url("no-final-newline.txt")).lineEndings
        #expect(open == LineEndings(lf: 1, hasFinalNewline: false))
        #expect(open.lineCount(byteCount: 7) == 2)
    }
}

@Suite struct DetectionTests {
    private func valid(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { Detection.isValidUTF8($0) }
    }

    @Test func utf8Validation() {
        #expect(valid([]))
        #expect(valid(Array("plain ASCII text that is longer than eight bytes".utf8)))
        #expect(valid(Array("café 日本 😀 Ελληνικά".utf8)))
        #expect(valid([0xF4, 0x8F, 0xBF, 0xBF]))           // U+10FFFF
        #expect(!valid([0xC0, 0xAF]))                       // overlong "/"
        #expect(!valid([0xE0, 0x80, 0xAF]))                 // overlong
        #expect(!valid([0xED, 0xA0, 0x80]))                 // surrogate
        #expect(!valid([0xF4, 0x90, 0x80, 0x80]))           // above U+10FFFF
        #expect(!valid(Array("abcdefgh".utf8) + [0xE6, 0x97]))  // truncated at the end
        #expect(!valid([0x80]))                             // stray continuation
        #expect(!valid([0xE9, 0x74, 0xE9]))                 // Latin-1 "été"
    }

    @Test func byteOrderMarks() {
        func mark(_ bytes: [UInt8]) -> String? {
            bytes.withUnsafeBufferPointer { Detection.byteOrderMark($0) }.map { "\($0.0.name)/\($0.1)" }
        }
        #expect(mark([0xEF, 0xBB, 0xBF, 0x41]) == "utf-8/3")
        #expect(mark([0xFF, 0xFE, 0x41, 0x00]) == "utf-16le/2")
        #expect(mark([0xFE, 0xFF, 0x00, 0x41]) == "utf-16be/2")
        #expect(mark([0xFF, 0xFE, 0x00, 0x00, 0x41, 0, 0, 0]) == "utf-32le/4")
        #expect(mark([0x00, 0x00, 0xFE, 0xFF]) == "utf-32be/4")
        #expect(mark([0x41]) == nil)
    }

    @Test func utf32WithBOMRoundTrips() throws {
        let text = "UTF-32 text: 日本 😀\n"
        let bytes = [0xFF, 0xFE, 0x00, 0x00] + Array(text.data(using: .utf32LittleEndian)!)
        let imported = try TextImport.decode(bytes)
        #expect(imported.encoding == .utf32LittleEndian)
        #expect(imported.string == text)
        #expect(imported.encoded() == bytes)
    }

    @Test func windows1252WithoutHighControlsIsLatin1() throws {
        let latin = Array("déjà vu\n".data(using: .isoLatin1)!)
        #expect(try TextImport.decode(latin, options: EncodingCorpus.options).encoding == .isoLatin1)
        let quotes = Array("“smart” quotes, 5 €, more words to read\n".data(using: .windowsCP1252)!)
        let imported = try TextImport.decode(quotes, options: EncodingCorpus.options)
        #expect(imported.encoding == .windowsCP1252)
        #expect(imported.string == "“smart” quotes, 5 €, more words to read\n")
        #expect(imported.encoded() == quotes)
    }

    @Test func singleByteTables() throws {
        let all = Array(0 ... 255).map(UInt8.init)
        let latin = try #require(SingleByte.decode(all[...], table: SingleByte.table(for: .isoLatin1)!))
        #expect(String(decoding: latin, as: UTF8.self) == String(data: Data(all), encoding: .isoLatin1))
        let defined = all.filter { ![0x81, 0x8D, 0x8F, 0x90, 0x9D].contains($0) }
        let cp = try #require(SingleByte.decode(defined[...], table: SingleByte.table(for: .windowsCP1252)!))
        #expect(String(decoding: cp, as: UTF8.self) == String(data: Data(defined), encoding: .windowsCP1252))
        #expect(SingleByte.decode([0x41, 0x81][...], table: SingleByte.table(for: .windowsCP1252)!) == nil)
    }
}

@Suite struct BinaryTests {
    @Test func signaturesAreBinary() throws {
        for file in ["image-png.bin", "archive.zip", "macho.bin", "random.bin"] {
            let imported = try TextImport.load(EncodingCorpus.url(file))
            #expect(imported.kind == .binary, "\(file)")
            #expect(imported.byteCount == (try EncodingCorpus.bytes(file)).count)
        }
    }

    @Test func realExecutableIsBinary() throws {
        #expect(try TextImport.load(URL(filePath: "/usr/bin/true")).kind == .binary)
    }

    @Test func nulBytesInValidUTF8OpenAsTextUnderTheLimit() throws {
        let bytes = Array("log line\n".utf8) + [0, 0, 0] + Array("next line\n".utf8)
        let imported = try TextImport.decode(bytes, fileName: "app.log")
        #expect(imported.kind == .text)
        #expect(imported.utf8 == bytes)
        // Over the limit, the same content is binary.
        let small = TextImport.Options(binaryTextLimit: 4)
        #expect(try TextImport.decode(bytes, fileName: "app.log", options: small).kind == .binary)
        // So is content that is not valid UTF-8.
        #expect(try TextImport.decode(bytes + [0xFF], fileName: "app.log").kind == .binary)
        // And an extension that names a binary type is never rescued.
        #expect(try TextImport.decode(bytes, fileName: "picture.jpg").kind == .binary)
    }

    @Test func controlCharactersMakeBinary() throws {
        // Many control bytes and NULs at both parities, not valid UTF-8.
        let noisy = (0 ..< 400).map { UInt8($0 % 3 == 0 ? 0x01 : ($0 % 7 == 0 ? 0x00 : 0x41)) } + [0xFF]
        #expect(try TextImport.decode(noisy).kind == .binary)
        // Without the NULs it decodes (as a single-byte encoding), so it
        // opens as text: "binary but decodable" under 50 MiB.
        let decodable = (0 ..< 400).map { UInt8($0 % 3 == 0 ? 0x01 : 0x41) } + [0xFF]
        #expect(try TextImport.decode(decodable, options: EncodingCorpus.options).kind == .text)
        #expect(try TextImport.decode(decodable, options: TextImport.Options(binaryTextLimit: 100)).kind == .binary)
        // A few escapes (coloured logs) are fine.
        let log = Array("\u{1B}[31merror\u{1B}[0m: failed\n".utf8)
        #expect(try TextImport.decode(log).kind == .text)
    }

    @Test func svgAndTextExtensionsAreNotBinaryTypes() {
        #expect(!TextImport.isBinaryType("svg"))
        #expect(!TextImport.isBinaryType("txt"))
        #expect(!TextImport.isBinaryType(""))
        #expect(TextImport.isBinaryType("png"))
        #expect(TextImport.isBinaryType("zip"))
    }
}

@Suite struct LoadTests {
    @Test func devNullIsEmptyText() throws {
        let imported = try TextImport.load(URL(filePath: "/dev/null"))
        #expect(imported.kind == .text)
        #expect(imported.utf8.isEmpty)
        #expect(imported.lineEndings.style == .none)
        #expect(imported.encoded() == [])
    }

    @Test func missingAndDirectory() throws {
        #expect(try TextImport.load(URL(filePath: "/nonexistent/prism/file.txt")).kind == .missing)
        #expect(try TextImport.load(EncodingCorpus.directory).kind == .directory)
    }

    @Test func remoteURLsAreRefused() {
        #expect(throws: ImportError.self) { try TextImport.load(URL(string: "https://example.com/a.txt")!) }
    }

    @Test func unreadableFile() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let file = dir.url.appending(path: "secret.txt")
        try Data("x\n".utf8).write(to: file)
        chmod(file.path(percentEncoded: false), 0)
        defer { chmod(file.path(percentEncoded: false), 0o644) }
        guard getuid() != 0 else { return }
        #expect {
            try TextImport.load(file)
        } throws: { error in
            (error as? ImportError).map { if case .unreadable = $0.reason { true } else { false } } ?? false
        }
    }

    @Test func sizeGuard() throws {
        let options = TextImport.Options(maximumSize: 10)
        #expect(throws: ImportError(path: EncodingCorpus.url("utf8.txt").path(percentEncoded: false),
                                    reason: .tooLarge(limit: 10))) {
            try TextImport.load(EncodingCorpus.url("utf8.txt"), options: options)
        }
        #expect(throws: ImportError.self) { try TextImport.decode(Array(repeating: 65, count: 11), options: options) }
        // The UTF-8 text may grow past the limit when it is decoded.
        let latin = Array(repeating: UInt8(0xE9), count: 8)
        #expect(throws: ImportError.self) { try TextImport.decode(latin, options: options) }
    }

    @Test func progressRisesToOne() throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var values: [Double] = []
            func add(_ v: Double) { lock.withLock { values.append(v) } }
        }
        let recorder = Recorder()
        let options = TextImport.Options(progress: { recorder.add($0) })
        _ = try TextImport.load(EncodingCorpus.url("latin1.txt"), options: options)
        let values = recorder.lock.withLock { recorder.values }
        #expect(!values.isEmpty)
        #expect(values == values.sorted())
        #expect(values.last == 1)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func documentsAreRecognisedByContentWithoutAnExtension() throws {
        let rtf = try EncodingCorpus.bytes("doc.rtf")
        let imported = try TextImport.decode(rtf, path: "-")
        #expect(imported.kind == .document)
        #expect(imported.documentFormat == .rtf)
        let pdf = try TextImport.decode(try EncodingCorpus.bytes("doc.pdf"))
        #expect(pdf.documentFormat == .pdf)
    }

    @Test func brokenDocumentIsAConversionError() {
        #expect {
            try TextImport.decode(Array("%PDF-1.4 not really".utf8), fileName: "broken.pdf")
        } throws: { error in
            (error as? ImportError).map { if case .conversionFailed(.pdf, _) = $0.reason { true } else { false } } ?? false
        }
    }

    @Test func rtfdPackage() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let package = dir.url.appending(path: "note.rtfd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(try EncodingCorpus.bytes("doc.rtf")).write(to: package.appending(path: "TXT.rtf"))
        let imported = try TextImport.load(package)
        #expect(imported.kind == .document)
        #expect(imported.documentFormat == .rtfd)
        #expect(imported.string == (try String(contentsOf: EncodingCorpus.url("doc.rtf.expected"), encoding: .utf8)))
    }

    @Test func largeUTF8FileImportsQuickly() throws {
        // 100 MB of ASCII lines; the acceptance script times the CLI too.
        let line = Array("The quick brown fox jumps over the lazy dog, 0123456789.\n".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(100_000_000 + line.count)
        while bytes.count < 100_000_000 { bytes.append(contentsOf: line) }
        let start = ContinuousClock.now
        let imported = try TextImport.decode(bytes, fileName: "big.txt")
        let elapsed = ContinuousClock.now - start
        #expect(imported.kind == .text)
        #expect(imported.lineEndings.lf == bytes.count / line.count)
        // Generous for debug builds and loaded machines.
        #expect(elapsed < .seconds(5))
    }
}

/// Regressions from the M2 review.
@Suite struct ReviewRegressionTests {
    static func binaryPlist(_ value: String) throws -> [UInt8] {
        Array(try PropertyListSerialization.data(fromPropertyList: ["k": value], format: .binary, options: 0))
    }

    @Test func binaryPropertyListsOpenAsXMLText() throws {
        let imported = try TextImport.decode(try Self.binaryPlist("v"), fileName: "settings.plist")
        #expect(imported.kind == .document)
        #expect(imported.documentFormat == .binaryPlist)
        #expect(imported.string.contains("<key>k</key>"))
        #expect(imported.string.contains("<string>v</string>"))
        #expect(!imported.roundTrips)
        #expect(imported.encoded() == nil)
        // A broken one is not a property list: classified by content.
        let broken = Array("bplist00".utf8) + [0, 1, 2, 0xFF]
        #expect(try TextImport.decode(broken).kind == .binary)
    }

    @Test func textThatStartsLikeADocumentIsText() throws {
        for content in ["%PDF-1.4 is a header\n", "{\\rtf is how rtf starts\n"] {
            let imported = try TextImport.decode(Array(content.utf8), fileName: "note.txt")
            #expect(imported.kind == .text, "\(content)")
            #expect(imported.string == content)
        }
        // A declared format still has to convert.
        #expect(throws: ImportError.self) {
            try TextImport.decode(Array("%PDF-1.4 is a header\n".utf8), fileName: "note.pdf")
        }
    }

    @Test func loneSurrogateAfterABOMIsTextThatDoesNotRoundTrip() throws {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x61, 0x00, 0x0A, 0x00, 0x00, 0xD8, 0x63, 0x00, 0x0A, 0x00]
        let imported = try TextImport.decode(bytes)
        #expect(imported.kind == .text)
        #expect(imported.encoding == .utf16LittleEndian)
        #expect(imported.string == "a\n\u{FFFD}c\n")
        #expect(!imported.roundTrips)
        // UTF-32 and UTF-8 with a BOM behave the same.
        let utf32: [UInt8] = [0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x61, 0x00, 0x11, 0x00, 0x00]
        let wide = try TextImport.decode(utf32)
        #expect(wide.kind == .text && wide.string == "a\u{FFFD}" && !wide.roundTrips)
        let utf8 = try TextImport.decode([0xEF, 0xBB, 0xBF, 0x61, 0xFF, 0x0A])
        #expect(utf8.kind == .text && utf8.string == "a\u{FFFD}\n" && !utf8.roundTrips)
    }

    @Test func strayLastByteAfterABOMBecomesAReplacementCharacter() throws {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00, 0x0A, 0x00, 0x68]
        let imported = try TextImport.decode(bytes)
        #expect(imported.string == "hi\n\u{FFFD}")
        #expect(!imported.roundTrips)
        #expect(imported.byteCount == bytes.count)
    }

    @Test func utf16StartingWithNULIsNotMistakenForUTF32() throws {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x0A, 0x00]
        let imported = try TextImport.decode(bytes)
        #expect(imported.encoding == .utf16LittleEndian)
        #expect(imported.string == "\u{0}a\n")
        #expect(imported.encoded() == bytes)
    }

    @Test func truncatedBOMLessUTF16IsStillUTF16() throws {
        let bytes = Array("hello world\nfoo bar\n".data(using: .utf16LittleEndian)!) + [0x78]
        let imported = try TextImport.decode(bytes)
        #expect(imported.encoding == .utf16LittleEndian)
        #expect(imported.string == "hello world\nfoo bar\n\u{FFFD}")
        #expect(!imported.roundTrips)
    }

    @Test func mostlyCJKBOMLessUTF16IsText() throws {
        for (text, encoding) in [("日本語のテキスト\n", String.Encoding.utf16LittleEndian),
                                 ("中文的文本内容\n", .utf16BigEndian)] {
            let bytes = Array(text.data(using: encoding)!)
            let imported = try TextImport.decode(bytes)
            #expect(imported.kind == .text, "\(text)")
            #expect(imported.encoding == TextEncoding(encoding))
            #expect(imported.string == text)
            #expect(imported.encoded() == bytes)
        }
        // Binary data with NULs at both parities stays binary.
        #expect(try TextImport.decode(try EncodingCorpus.bytes("random.bin")).kind == .binary)
    }

    @Test func controlCharactersInLatin1AreRescued() throws {
        let line: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x20, 0x01, 0x02, 0x03, 0x0A]
        let bytes = Array([[UInt8]](repeating: line, count: 10).joined())
        let imported = try TextImport.decode(bytes, fileName: "log.txt", options: EncodingCorpus.options)
        #expect(imported.kind == .text)
        #expect(imported.string.hasPrefix("café \u{1}\u{2}\u{3}\n"))
        // Not with a NUL, and not past the limit or with a binary type.
        #expect(try TextImport.decode(bytes + [0], fileName: "log.txt").kind == .binary)
        #expect(try TextImport.decode(bytes, fileName: "log.png").kind == .binary)
        #expect(try TextImport.decode(bytes, options: TextImport.Options(binaryTextLimit: 10)).kind == .binary)
    }

    @Test func roundTripOfOtherEncodingsIsCheckedOnASample() throws {
        // About 3 MB of Shift JIS: decoding must not re-encode it all.
        let line = "吾輩は猫である。名前はまだ無い。\n"
        let bytes = Array(String(repeating: line, count: 100_000).data(using: .shiftJIS)!)
        let start = ContinuousClock.now
        let imported = try TextImport.decode(bytes, options: EncodingCorpus.options)
        let elapsed = ContinuousClock.now - start
        #expect(imported.encoding == .shiftJIS)
        #expect(imported.roundTrips)
        #expect(imported.encoded() == bytes)
        #expect(elapsed < .seconds(5))
    }
}
