// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// A file turned into diffable text, with everything needed to write it
/// back the way it was read.
///
/// The text itself is always held as UTF-8 bytes without a byte order mark
/// (`utf8`), which is what the diff engine consumes. Line terminators are
/// kept exactly as they were (never normalised), so `utf8` re-encoded with
/// `encoding` and prefixed with the BOM when `hasBOM` is set gives back the
/// original bytes; `encoded()` does that, and `roundTrips` says whether the
/// result is byte-identical to the source.
///
/// Only `.text` and `.document` carry text; for the other kinds `utf8` is
/// empty and `encoding` is nil.
public struct ImportedText: Sendable, Equatable {

    /// What the file turned out to be.
    public enum Kind: String, Sendable, Equatable {
        /// Plain text in a detected encoding.
        case text
        /// A rich-text or PDF document whose plain text was extracted
        /// (`documentFormat` says which). It cannot be saved back as is.
        case document
        /// Not text: a known binary signature, or bytes that no supported
        /// encoding explains (see `TextImport` for the rules).
        case binary
        /// A folder (folders are compared by another part of the app).
        case directory
        /// Nothing exists at the path. `/dev/null` is not missing: it reads
        /// as empty text, as version control tools expect for added and
        /// deleted files.
        case missing
    }

    public var kind: Kind
    /// The text as UTF-8, without a byte order mark. Empty unless `kind` is
    /// `.text` or `.document`.
    public var utf8: [UInt8]
    /// The encoding the bytes were read in; nil unless `kind` is `.text`.
    public var encoding: TextEncoding?
    /// True when the source started with a byte order mark (`encoding`
    /// says which one).
    public var hasBOM: Bool
    /// How the lines of `utf8` end.
    public var lineEndings: LineEndings
    /// The rich-text or PDF format of a `.document`; nil otherwise.
    public var documentFormat: DocumentFormat?
    /// Size of the source in bytes (for a document package, of its main
    /// file; 0 for a missing file or a folder).
    public var byteCount: Int
    /// True when `encoded()` reproduces the source bytes exactly. Always
    /// true for UTF-8; checked once at import for other encodings. A file
    /// that does not round-trip should not be saved over without asking.
    public var roundTrips: Bool

    public init(kind: Kind, utf8: [UInt8] = [], encoding: TextEncoding? = nil, hasBOM: Bool = false,
                lineEndings: LineEndings = LineEndings(), documentFormat: DocumentFormat? = nil,
                byteCount: Int = 0, roundTrips: Bool = false) {
        self.kind = kind
        self.utf8 = utf8
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEndings = lineEndings
        self.documentFormat = documentFormat
        self.byteCount = byteCount
        self.roundTrips = roundTrips
    }

    /// True for the kinds that carry text (`.text` and `.document`).
    public var isText: Bool { kind == .text || kind == .document }

    /// The text as a Swift string.
    public var string: String { String(decoding: utf8, as: UTF8.self) }

    /// The text encoded back into its original encoding, BOM included: the
    /// bytes to write when saving. Nil when the kind is not `.text` or the
    /// text cannot be represented in that encoding.
    public func encoded() -> [UInt8]? {
        guard kind == .text, let encoding else { return nil }
        return encoding.encode(utf8, withBOM: hasBOM)
    }
}

/// A text encoding, identified by its Foundation value, with a stable
/// lower-case name for reports and JSON.
public struct TextEncoding: Sendable, Hashable, CustomStringConvertible {
    public let stringEncoding: String.Encoding

    public init(_ stringEncoding: String.Encoding) {
        self.stringEncoding = stringEncoding
    }

    public static let utf8 = TextEncoding(.utf8)
    public static let utf16LittleEndian = TextEncoding(.utf16LittleEndian)
    public static let utf16BigEndian = TextEncoding(.utf16BigEndian)
    public static let utf32LittleEndian = TextEncoding(.utf32LittleEndian)
    public static let utf32BigEndian = TextEncoding(.utf32BigEndian)
    public static let isoLatin1 = TextEncoding(.isoLatin1)
    public static let windowsCP1252 = TextEncoding(.windowsCP1252)
    public static let shiftJIS = TextEncoding(.shiftJIS)

    /// The IANA charset name in lower case (`utf-8`, `utf-16le`,
    /// `iso-8859-1`, `shift_jis`, ...), or `x-encoding-<n>` when there is
    /// none.
    public var name: String {
        switch stringEncoding {
        case .utf8: return "utf-8"
        case .utf16LittleEndian: return "utf-16le"
        case .utf16BigEndian: return "utf-16be"
        case .utf32LittleEndian: return "utf-32le"
        case .utf32BigEndian: return "utf-32be"
        case .isoLatin1: return "iso-8859-1"
        case .windowsCP1252: return "windows-1252"
        case .shiftJIS: return "shift_jis"
        default:
            let cf = CFStringConvertNSStringEncodingToEncoding(stringEncoding.rawValue)
            if let iana = CFStringConvertEncodingToIANACharSetName(cf) {
                return (iana as String).lowercased()
            }
            return "x-encoding-\(stringEncoding.rawValue)"
        }
    }

    public var description: String { name }

    /// The byte order mark written before text in this encoding, when the
    /// source had one.
    public var byteOrderMark: [UInt8] {
        switch stringEncoding {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        case .utf32LittleEndian: return [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndian: return [0x00, 0x00, 0xFE, 0xFF]
        default: return []
        }
    }

    /// `utf8` re-encoded in this encoding, preceded by the BOM when
    /// `withBOM` is set. Nil when a character has no representation.
    public func encode(_ utf8: [UInt8], withBOM: Bool) -> [UInt8]? {
        var out = withBOM ? byteOrderMark : []
        if stringEncoding == .utf8 {
            out.append(contentsOf: utf8)
            return out
        }
        guard let data = String(decoding: utf8, as: UTF8.self).data(using: stringEncoding,
                                                                    allowLossyConversion: false)
        else { return nil }
        out.append(contentsOf: data)
        return out
    }
}

/// The line terminators found in a text, by kind.
public struct LineEndings: Sendable, Equatable {
    /// The dominant style.
    public enum Style: String, Sendable, Equatable {
        /// No terminator at all (empty, or a single unterminated line).
        case none
        /// Unix: LF.
        case lf
        /// Windows: CR LF.
        case crlf
        /// Classic Mac OS: a lone CR.
        case cr
        /// More than one kind.
        case mixed
    }

    public var lf: Int
    public var crlf: Int
    public var cr: Int
    /// True when the last line ends with a terminator.
    public var hasFinalNewline: Bool

    public init(lf: Int = 0, crlf: Int = 0, cr: Int = 0, hasFinalNewline: Bool = false) {
        self.lf = lf
        self.crlf = crlf
        self.cr = cr
        self.hasFinalNewline = hasFinalNewline
    }

    public var style: Style {
        switch (lf > 0, crlf > 0, cr > 0) {
        case (false, false, false): .none
        case (true, false, false): .lf
        case (false, true, false): .crlf
        case (false, false, true): .cr
        default: .mixed
        }
    }

    /// Number of lines, counting an unterminated last line.
    public func lineCount(byteCount: Int) -> Int {
        let terminated = lf + crlf + cr
        return byteCount == 0 ? 0 : terminated + (hasFinalNewline ? 0 : 1)
    }
}

/// Documents whose plain text is extracted on import.
public enum DocumentFormat: String, Sendable, Equatable, CaseIterable {
    case rtf, rtfd, doc, docx, wordml, odt, pdf
    /// A binary property list, shown as its XML form.
    case binaryPlist = "bplist"
}
