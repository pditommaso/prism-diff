// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import os
import PrismProtocol
import TextImport

/// A file's content, ready for the diff engine and for display.
struct LoadedText: Sendable, Equatable {
    /// UTF-8 bytes that are diffed and drawn. A source that decodes another
    /// encoding hands over its UTF-8 transcoding here.
    var bytes: [UInt8]
    /// Short description of how the bytes were read, for example "UTF-8".
    var encodingName: String
    /// True when the input had to be repaired (ill-formed sequences were
    /// replaced by U+FFFD).
    var isLossy: Bool
    /// How to write the text back to its file; nil when it cannot be saved
    /// (a converted document, or text that had to be repaired).
    var format: SaveFormat? = nil
}

/// The encoding details needed to save edited text the way it was read.
struct SaveFormat: Sendable, Equatable {
    var encoding: TextEncoding
    var hasBOM: Bool
    /// False when re-encoding the unedited text would not give back the
    /// original bytes: saving should ask first.
    var roundTrips: Bool

    static let utf8 = SaveFormat(encoding: .utf8, hasBOM: false, roundTrips: true)

    /// `utf8` in this format, ready to write; nil when a character cannot
    /// be represented in the encoding.
    func encode(_ utf8: [UInt8]) -> [UInt8]? {
        ImportedText(kind: .text, utf8: utf8, encoding: encoding, hasBOM: hasBOM, roundTrips: roundTrips).encoded()
    }
}

/// Turns a file on disk into `LoadedText`. The viewer depends only on this
/// protocol, so a smarter importer (encoding detection, BOMs, UTF-16) can
/// replace the plain UTF-8 reader without touching the view code.
protocol TextSource: Sendable {
    func load(_ url: URL) throws -> LoadedText
}

/// The source used by new comparisons.
enum TextSources {
    static let current: any TextSource = ImportedTextSource()
}

/// Reads a file as UTF-8. Ill-formed input is decoded lossily: each
/// ill-formed subsequence becomes U+FFFD, so what is drawn is always valid.
struct UTF8TextSource: TextSource {
    func load(_ url: URL) throws -> LoadedText {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return Self.decode(data)
    }

    static func decode<Bytes: Collection>(_ data: Bytes) -> LoadedText where Bytes.Element == UInt8 {
        var bytes = [UInt8](data)
        var lossy = false
        // A UTF-8 byte order mark is not content.
        let hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        if hasBOM {
            bytes.removeFirst(3)
        }
        // Decoding repairs ill-formed input; valid input round-trips unchanged.
        let decoded = String(decoding: bytes, as: UTF8.self)
        if !decoded.utf8.elementsEqual(bytes) {
            bytes = Array(decoded.utf8)
            lossy = true
        }
        return LoadedText(bytes: bytes, encodingName: lossy ? "UTF-8 (repaired)" : "UTF-8", isLossy: lossy,
                          format: lossy ? nil : SaveFormat(encoding: .utf8, hasBOM: hasBOM, roundTrips: true))
    }
}

/// Reads a file through TextImport: encoding detection, BOMs, UTF-16 and
/// document conversion. Binary files and folders are refused with a
/// message, as is a path that does not exist.
struct ImportedTextSource: TextSource {
    struct Refused: Error, LocalizedError {
        var errorDescription: String?
    }

    func load(_ url: URL) throws -> LoadedText {
        let imported: ImportedText
        do {
            imported = try TextImport.load(url)
        } catch {
            PrismLog.import.error("cannot import a file: \(error.description, privacy: .private)")
            throw Refused(errorDescription: error.description)
        }
        switch imported.kind {
        case .text, .document:
            // Only plain text in a known encoding can be written back; a
            // file that does not round-trip may still be saved, after a
            // warning.
            let format = imported.kind == .text ? imported.encoding.map {
                SaveFormat(encoding: $0, hasBOM: imported.hasBOM, roundTrips: imported.roundTrips)
            } : nil
            return LoadedText(bytes: imported.utf8, encodingName: imported.encoding?.name ?? "UTF-8",
                              isLossy: !imported.roundTrips, format: format)
        case .missing:
            throw Refused(errorDescription: "\(url.path) does not exist.")
        case .binary:
            throw Refused(errorDescription: "\(url.lastPathComponent) is a binary file; only text can be compared.")
        case .directory:
            throw Refused(errorDescription: "\(url.lastPathComponent) is a folder; a folder can only be compared with another folder.")
        }
    }
}
