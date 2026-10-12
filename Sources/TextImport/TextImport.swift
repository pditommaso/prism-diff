// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import UniformTypeIdentifiers

/// Turns files into diffable text: encoding and byte order mark detection,
/// line endings, binary detection, and plain-text extraction from rich-text
/// and PDF documents.
///
/// ## Public API
///
///     let imported = try TextImport.load(url)          // a file URL
///     let imported = try TextImport.decode(bytes, fileName: "notes.txt")
///
///     switch imported.kind {
///     case .text, .document: use(imported.utf8)        // or imported.string
///     case .binary:          showBinaryPlaceholder()
///     case .missing:         treatAsEmpty()            // nothing at the path
///     case .directory:       openFolderComparison()
///     }
///
/// `roundTrips` is exact for Unicode and single-byte encodings; for other
/// encodings (Shift JIS, ...) it is checked on the first MiB only.
///
/// `ImportedText` carries the decoded text as UTF-8 bytes (`utf8`, what
/// `DiffCore` takes; `string` for a Swift string), the source `encoding`,
/// `hasBOM`, the `lineEndings` (counts and dominant style, never
/// normalised), the `documentFormat` of converted documents, and
/// `encoded()`, which writes the text back in its original encoding with
/// its BOM. `roundTrips` says whether that is byte-identical to the source.
///
/// `load` and `decode` are synchronous and thread-safe; call them off the
/// main thread for big files. `Options.progress` reports progress from 0 to
/// 1 on the calling thread. Errors are `ImportError`: an unreadable path, a
/// file over `Options.maximumSize`, or a document that failed to convert.
///
/// ## Rules
///
/// In order:
/// 1. `/dev/null` (and any empty input) is empty UTF-8 text.
/// 2. Documents: a file whose extension is RTF, RTFD, DOC, DOCX, WordML or
///    ODT is converted through `NSAttributedString`, a PDF through PDFKit;
///    content starting with `{\rtf` or `%PDF-` is converted too. Extracted
///    text gets a final LF when it lacks one.
///    A binary property list is converted to XML text (a `.document` of
///    format `.binaryPlist`). When only the content suggested RTF or PDF
///    and the conversion fails, the file is read as text instead.
/// 3. A byte order mark (UTF-8, UTF-16 or UTF-32, either byte order)
///    decides the encoding, and the file is never binary: ill-formed units
///    (a lone surrogate, a stray last byte) become U+FFFD and `roundTrips`
///    is false. `FF FE 00 00` is UTF-32 LE only when the rest reads as
///    UTF-32; otherwise it is UTF-16 LE starting with U+0000.
/// 4. Binary: a known binary signature (PNG, JPEG, GIF, TIFF, Mach-O, ELF,
///    zip, gzip, xz, 7z, zstd, tar, SQLite, WebAssembly) is
///    binary. Otherwise the first 64 KiB are profiled: a NUL byte that
///    BOM-less UTF-16 does not explain, or more than 10% control bytes,
///    makes the file look binary. Such a file is still text when its NULs
///    all sit at one byte parity and it decodes cleanly as UTF-16 into
///    characters that read as text (`Detection.looksLikeText`), or when it is at most `Options.binaryTextLimit` (50 MiB)
///    bytes, its extension does not name an image, audio, video, archive,
///    executable, font or disk image type, and it is valid UTF-8 or (if it
///    has no NUL) Foundation's detector finds an encoding for it.
/// 5. BOM-less UTF-16, recognised by its NUL pattern in the first 64 KiB
///    (a NUL in most units, all at one parity), decoded leniently.
/// 6. Valid UTF-8 is UTF-8.
/// 7. Foundation's encoding detection on the first MiB (Windows-1252 and
///    Shift JIS suggested, `Options.likelyLanguage` as the language hint). Windows-1252 text without any byte in
///    0x80-0x9F is reported as ISO-8859-1, its subset.
/// 8. A fallback list: Windows-1252, then ISO-8859-1, which decodes any
///    byte sequence.
public enum TextImport {

    /// Import settings.
    public struct Options: Sendable {
        /// Largest source accepted, in bytes; also the largest UTF-8 text
        /// produced. The default is the diff engine's limit (2 GiB - 2).
        public var maximumSize: Int
        /// A file that looks binary by content is still read as text up to
        /// this size when it decodes (rule 4). Default 50 MiB.
        public var binaryTextLimit: Int
        /// ISO 639 code of the language the text is most likely in, a hint
        /// for the encoding detector (rule 7). Defaults to the language of
        /// the current locale.
        public var likelyLanguage: String?
        /// Called with values from 0 to 1 while reading and decoding.
        public var progress: (@Sendable (Double) -> Void)?

        public init(maximumSize: Int = TextImport.defaultMaximumSize,
                    binaryTextLimit: Int = TextImport.defaultBinaryTextLimit,
                    likelyLanguage: String? = Locale.current.language.languageCode?.identifier,
                    progress: (@Sendable (Double) -> Void)? = nil) {
            self.maximumSize = maximumSize
            self.binaryTextLimit = binaryTextLimit
            self.likelyLanguage = likelyLanguage
            self.progress = progress
        }
    }

    /// The diff engine stores offsets as 32-bit integers.
    public static let defaultMaximumSize = Int(Int32.max) - 1
    /// 50 MiB.
    public static let defaultBinaryTextLimit = 50 << 20

    /// Bytes read per `read(2)` call, between two progress reports.
    static let chunkSize = 16 << 20
    /// Bytes handed to Foundation's encoding detector.
    static let detectionSampleSize = 1 << 20

    // MARK: Entry points

    /// Imports the file at `url`, which must be a file URL. A missing path
    /// gives `.missing`, a folder `.directory` (an RTFD package is a
    /// document, not a folder).
    public static func load(_ url: URL, options: Options = Options()) throws(ImportError) -> ImportedText {
        let path = url.path(percentEncoded: false)
        guard url.isFileURL else { throw ImportError(path: url.absoluteString, reason: .notAFile) }
        var info = stat()
        if stat(path, &info) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return ImportedText(kind: .missing) }
            throw ImportError(path: path, reason: .unreadable(String(cString: strerror(code))))
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            if documentFormat(forExtension: url.pathExtension) == .rtfd {
                return try convertPackage(url, path: path, options: options)
            }
            return ImportedText(kind: .directory)
        }
        let bytes = try read(path, options: options)
        return try decode(bytes, fileName: url.lastPathComponent, path: path, options: options,
                          progressBase: 0.5)
    }

    /// Imports bytes that were already read (a pipe, standard input, a
    /// buffer). `fileName` supplies the extension used to recognise
    /// documents and binary types; `path` names the input in errors.
    public static func decode(_ bytes: [UInt8], fileName: String? = nil, path: String? = nil,
                              options: Options = Options()) throws(ImportError) -> ImportedText {
        try decode(bytes, fileName: fileName, path: path ?? fileName ?? "-", options: options, progressBase: 0)
    }

    // MARK: Pipeline

    private static func decode(_ bytes: [UInt8], fileName: String?, path: String, options: Options,
                               progressBase: Double) throws(ImportError) -> ImportedText {
        guard bytes.count <= options.maximumSize else {
            throw ImportError(path: path, reason: .tooLarge(limit: options.maximumSize))
        }
        let ext = fileName.map { ($0 as NSString).pathExtension } ?? ""
        let report = options.progress
        report?(progressBase)
        defer { report?(1) }

        // 1. Empty.
        if bytes.isEmpty {
            return ImportedText(kind: .text, encoding: .utf8, roundTrips: true)
        }

        // 2. Documents. When only the content suggested a format (a text file
        // that happens to start with "%PDF-"), a failed conversion falls back
        // to reading the file as text.
        let declared = documentFormat(forExtension: ext)
        let sniffed = bytes.withUnsafeBufferPointer { Detection.documentSignature($0) }
        if let format = declared {
            return try convertDocument(bytes, format: format, path: path, options: options)
        }
        if let format = sniffed, let document = try? convertDocument(bytes, format: format, path: path,
                                                                     options: options) {
            return document
        }
        if bytes.withUnsafeBufferPointer({ Detection.isBinaryPropertyList($0) }),
           let document = try convertPropertyList(bytes, path: path, options: options) {
            return document
        }

        // 3. Byte order mark: it decides, whatever follows. Ill-formed units
        // become U+FFFD and the text no longer round-trips.
        if var (encoding, length) = bytes.withUnsafeBufferPointer({ Detection.byteOrderMark($0) }) {
            if encoding == .utf32LittleEndian
                && !Detection.isPlausibleUTF32(bytes[4...], littleEndian: true) {
                (encoding, length) = (.utf16LittleEndian, 2)
            }
            return try unicodeText(bytes, from: length, encoding: encoding, path: path, options: options)
        }

        // 4. Binary.
        let (signature, profile) = bytes.withUnsafeBufferPointer {
            (Detection.hasBinarySignature($0), Detection.profile($0))
        }
        if signature { return binary(bytes) }
        report?(progressBase + (1 - progressBase) * 0.25)
        let validUTF8 = bytes.withUnsafeBufferPointer { Detection.isValidUTF8($0) }
        if profile.looksBinary {
            // NULs all at one parity: UTF-16 with few NULs (CJK text, say).
            if let utf16 = profile.nulParity {
                let text = try unicodeText(bytes, from: 0, encoding: utf16, path: path, options: options)
                if text.roundTrips && Detection.looksLikeText(text.utf8) { return text }
            }
            let rescuable = bytes.count <= options.binaryTextLimit && !isBinaryType(ext)
            if rescuable && validUTF8 {
                return text(bytes, encoding: .utf8, hasBOM: false, roundTrips: true)
            }
            // Control characters in another encoding. A NUL is never text in
            // a byte-oriented encoding (UTF-16 was tried above), so that case
            // stays binary.
            if rescuable && !profile.hasNUL,
               let detected = detectEncoding(bytes, language: options.likelyLanguage),
               let text = try decodeText(bytes, from: 0, encoding: detected, path: path, options: options) {
                return text
            }
            return binary(bytes)
        }

        // 5. BOM-less UTF-16 (its NULs are valid UTF-8, so it goes first).
        if let utf16 = profile.utf16 {
            return try unicodeText(bytes, from: 0, encoding: utf16, path: path, options: options)
        }

        // 6. UTF-8.
        if validUTF8 { return text(bytes, encoding: .utf8, hasBOM: false, roundTrips: true) }

        // 7. Foundation's detector.
        report?(progressBase + (1 - progressBase) * 0.5)
        if let detected = detectEncoding(bytes, language: options.likelyLanguage),
           let text = try decodeText(bytes, from: 0, encoding: detected, path: path, options: options) {
            return text
        }

        // 8. Fallbacks; ISO-8859-1 always succeeds.
        for encoding in [TextEncoding.windowsCP1252, .isoLatin1] {
            if let text = try decodeText(bytes, from: 0, encoding: encoding, path: path, options: options) {
                return text
            }
        }
        return binary(bytes)
    }

    /// The source decoded as `encoding`, starting at byte `offset` (after a
    /// BOM). Nil when the bytes are not valid in that encoding.
    private static func decodeText(_ bytes: [UInt8], from offset: Int, encoding: TextEncoding, path: String,
                                   options: Options) throws(ImportError) -> ImportedText? {
        let body = bytes[offset...]
        if encoding == .utf8 {
            guard body.withUnsafeBufferPointer({ Detection.isValidUTF8($0) }) else { return nil }
            return text(Array(body), encoding: .utf8, hasBOM: offset > 0, roundTrips: true,
                        byteCount: bytes.count)
        }
        if isUnicode(encoding) {
            let decoded = try unicodeText(bytes, from: offset, encoding: encoding, path: path, options: options)
            return decoded.roundTrips ? decoded : nil
        }
        var used = encoding
        if encoding == .windowsCP1252 && !body.contains(where: { $0 >= 0x80 && $0 <= 0x9F }) {
            used = .isoLatin1
        }
        let utf8: [UInt8]
        let roundTrips: Bool
        if let table = SingleByte.table(for: used) {
            // Every byte maps to one character and back: no Foundation pass.
            guard let decoded = SingleByte.decode(body, table: table) else { return nil }
            utf8 = decoded
            roundTrips = true
        } else {
            guard let string = String(data: Data(body), encoding: used.stringEncoding) else { return nil }
            utf8 = Array(string.utf8)
            roundTrips = sampleRoundTrips(body, encoding: used)
        }
        guard utf8.count <= options.maximumSize else {
            throw ImportError(path: path, reason: .tooLarge(limit: options.maximumSize))
        }
        return text(utf8, encoding: used, hasBOM: offset > 0, roundTrips: roundTrips, byteCount: bytes.count)
    }

    /// UTF-8, UTF-16 or UTF-32 from byte `offset` on, decoded leniently:
    /// ill-formed units and a stray trailing byte become U+FFFD, and the
    /// result then does not round-trip.
    private static func unicodeText(_ bytes: [UInt8], from offset: Int, encoding: TextEncoding, path: String,
                                    options: Options) throws(ImportError) -> ImportedText {
        let (utf8, clean) = Detection.decodeUnicode(bytes[offset...], encoding)
        guard utf8.count <= options.maximumSize else {
            throw ImportError(path: path, reason: .tooLarge(limit: options.maximumSize))
        }
        return text(utf8, encoding: encoding, hasBOM: offset > 0, roundTrips: clean, byteCount: bytes.count)
    }

    private static func isUnicode(_ encoding: TextEncoding) -> Bool {
        [.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian].contains(encoding)
    }

    /// Whether the first `detectionSampleSize` bytes of `body` (cut back to
    /// the last LF) encode back to themselves. Checking the whole text would
    /// double the cost of a big import; saving verifies the full text.
    private static func sampleRoundTrips(_ body: ArraySlice<UInt8>, encoding: TextEncoding) -> Bool {
        var end = body.startIndex + min(body.count, detectionSampleSize)
        if end < body.endIndex, let newline = body[..<end].lastIndex(of: 10), newline > body.startIndex {
            end = newline + 1
        }
        let sample = body[..<end]
        guard let string = String(data: Data(sample), encoding: encoding.stringEncoding) else { return false }
        return encoding.encode(Array(string.utf8), withBOM: false).map { $0.elementsEqual(sample) } ?? false
    }

    private static func text(_ utf8: [UInt8], encoding: TextEncoding, hasBOM: Bool, roundTrips: Bool,
                             byteCount: Int? = nil) -> ImportedText {
        let endings = utf8.withUnsafeBufferPointer { Detection.lineEndings($0) }
        return ImportedText(kind: .text, utf8: utf8, encoding: encoding, hasBOM: hasBOM, lineEndings: endings,
                            byteCount: byteCount ?? utf8.count, roundTrips: roundTrips)
    }

    private static func binary(_ bytes: [UInt8]) -> ImportedText {
        ImportedText(kind: .binary, byteCount: bytes.count)
    }

    /// Foundation's guess for the first `detectionSampleSize` bytes, cut
    /// back to the last LF so that no character is split.
    private static func detectEncoding(_ bytes: [UInt8], language: String?) -> TextEncoding? {
        var end = min(bytes.count, detectionSampleSize)
        if end < bytes.count, let newline = bytes[..<end].lastIndex(of: 10), newline > 0 {
            end = newline + 1
        }
        let sample = Data(bytes[..<end])
        var converted: NSString?
        var lossy: ObjCBool = false
        let suggested = [String.Encoding.windowsCP1252.rawValue, String.Encoding.shiftJIS.rawValue]
        var detectionOptions: [StringEncodingDetectionOptionsKey: Any] = [
            .allowLossyKey: false,
            .suggestedEncodingsKey: suggested,
        ]
        if let language { detectionOptions[.likelyLanguageKey] = language }
        let raw = NSString.stringEncoding(for: sample, encodingOptions: detectionOptions,
                                          convertedString: &converted, usedLossyConversion: &lossy)
        guard raw != 0, !lossy.boolValue else { return nil }
        return TextEncoding(String.Encoding(rawValue: raw))
    }

    // MARK: Types

    /// The document format named by a file extension, if any.
    static func documentFormat(forExtension ext: String) -> DocumentFormat? {
        guard !ext.isEmpty else { return nil }
        // Packages (RTFD) are not found under the default `public.data`.
        let types = [UTType(filenameExtension: ext), UTType(filenameExtension: ext, conformingTo: .package)]
            .compactMap { $0 }.filter { !$0.isDynamic }
        guard let type = types.first else { return nil }
        let table: [(String, DocumentFormat)] = [
            (UTType.rtfd.identifier, .rtfd),
            (UTType.flatRTFD.identifier, .rtfd),
            (UTType.rtf.identifier, .rtf),
            (UTType.pdf.identifier, .pdf),
            ("org.openxmlformats.wordprocessingml.document", .docx),
            ("com.microsoft.word.doc", .doc),
            ("com.microsoft.word.wordml", .wordml),
            ("org.oasis-open.opendocument.text", .odt),
        ]
        for (identifier, format) in table {
            if let other = UTType(identifier), type.conforms(to: other) { return format }
        }
        return nil
    }

    /// True when the extension names a type that is never text.
    static func isBinaryType(_ ext: String) -> Bool {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .svg) || type.conforms(to: .text) { return false }
        let families: [UTType] = [.image, .audiovisualContent, .archive, .executable, .font, .diskImage]
        return families.contains { type.conforms(to: $0) }
    }

    // MARK: Reading

    /// Reads a file (or FIFO, or device) to its end, refusing more than
    /// `options.maximumSize` bytes, reporting progress per chunk.
    static func read(_ path: String, options: Options) throws(ImportError) -> [UInt8] {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ImportError(path: path, errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ImportError(path: path, errno: errno) }
        let isRegular = info.st_mode & S_IFMT == S_IFREG
        let size = isRegular ? Int(info.st_size) : 0
        let limit = options.maximumSize
        if size > limit { throw ImportError(path: path, reason: .tooLarge(limit: limit)) }

        var bytes = [UInt8](repeating: 0, count: max(size + 1, 64 << 10))
        var count = 0
        while true {
            if count == bytes.count {
                if count > limit { throw ImportError(path: path, reason: .tooLarge(limit: limit)) }
                bytes.append(contentsOf: repeatElement(0, count: min(count * 2, limit + 1) - count))
            }
            let want = min(bytes.count - count, chunkSize)
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + count, want) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ImportError(path: path, errno: errno)
            }
            if n == 0 { break }
            count += n
            if size > 0 { options.progress?(0.5 * Double(min(count, size)) / Double(size)) }
        }
        if count > limit { throw ImportError(path: path, reason: .tooLarge(limit: limit)) }
        bytes.removeSubrange(count...)
        return bytes
    }
}

/// Why a file could not be imported.
public struct ImportError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        /// The system refused to read it; the associated text is its reason.
        case unreadable(String)
        /// Larger than `Options.maximumSize` (before or after decoding).
        case tooLarge(limit: Int)
        /// A document whose text could not be extracted.
        case conversionFailed(DocumentFormat, String)
        /// Not a file URL.
        case notAFile
    }

    /// The path (or name) of the input.
    public let path: String
    public let reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }

    init(path: String, errno code: Int32) {
        self.init(path: path, reason: .unreadable(String(cString: strerror(code))))
    }

    /// The reason in words, to follow "<path>: ".
    public var message: String {
        switch reason {
        case .unreadable(let text): text
        case .tooLarge(let limit): "file too large (the limit is \(limit) bytes)"
        case .conversionFailed(let format, let text): "cannot extract the text of this \(format.rawValue.uppercased()) document (\(text))"
        case .notAFile: "only local files can be read"
        }
    }

    public var description: String { "\(path): \(message)" }
}
