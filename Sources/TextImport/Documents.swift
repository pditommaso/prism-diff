// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PDFKit

// Plain-text extraction from rich-text documents (through the Cocoa text
// system) and PDF files (through PDFKit).

extension TextImport {

    /// The text of a document held in `bytes`.
    static func convertDocument(_ bytes: [UInt8], format: DocumentFormat, path: String,
                                options: Options) throws(ImportError) -> ImportedText {
        let data = Data(bytes)
        let string: String
        switch format {
        case .pdf:
            guard let document = PDFDocument(data: data) else {
                throw ImportError(path: path, reason: .conversionFailed(.pdf, "not a readable PDF"))
            }
            string = document.string ?? ""
        case .rtfd:
            // Flat RTFD (a single file); a package is read by `convertPackage`.
            string = try attributedText(path: path, format: format) {
                try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                       documentAttributes: nil)
            }
        default:
            string = try attributedText(path: path, format: format) {
                try NSAttributedString(data: data, options: [.documentType: documentType(format)],
                                       documentAttributes: nil)
            }
        }
        return try documentText(string, format: format, byteCount: bytes.count, path: path, options: options)
    }

    /// The text of an RTFD package (a folder).
    static func convertPackage(_ url: URL, path: String, options: Options) throws(ImportError) -> ImportedText {
        let string = try attributedText(path: path, format: .rtfd) {
            try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                   documentAttributes: nil)
        }
        var size = stat()
        let main = url.appending(path: "TXT.rtf").path(percentEncoded: false)
        let byteCount = stat(main, &size) == 0 ? Int(size.st_size) : 0
        return try documentText(string, format: .rtfd, byteCount: byteCount, path: path, options: options)
    }

    private static func documentType(_ format: DocumentFormat) -> NSAttributedString.DocumentType {
        switch format {
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .doc: .docFormat
        case .docx: .officeOpenXML
        case .wordml: .wordML
        case .odt: .openDocument
        case .pdf, .binaryPlist: .plain  // never used: PDFKit and PropertyListSerialization
        }
    }

    private static func attributedText(path: String, format: DocumentFormat,
                                       _ make: () throws -> NSAttributedString) throws(ImportError) -> String {
        do {
            return try make().string
        } catch {
            throw ImportError(path: path, reason: .conversionFailed(format, error.localizedDescription))
        }
    }

    /// Extracted text as an imported document: attachment placeholders
    /// (U+FFFC) dropped, and a final LF added when the text does not end
    /// with a line break.
    private static func documentText(_ string: String, format: DocumentFormat, byteCount: Int, path: String,
                                     options: Options) throws(ImportError) -> ImportedText {
        var text = string.replacingOccurrences(of: "\u{FFFC}", with: "")
        if let last = text.unicodeScalars.last, last != "\n", last != "\r" {
            text += "\n"
        }
        let utf8 = Array(text.utf8)
        guard utf8.count <= options.maximumSize else {
            throw ImportError(path: path, reason: .tooLarge(limit: options.maximumSize))
        }
        let endings = utf8.withUnsafeBufferPointer { Detection.lineEndings($0) }
        return ImportedText(kind: .document, utf8: utf8, encoding: nil, lineEndings: endings,
                            documentFormat: format, byteCount: byteCount, roundTrips: false)
    }
}

extension TextImport {

    /// A binary property list as its XML form, or nil when the bytes do
    /// not parse as one (they are then classified like any other file).
    static func convertPropertyList(_ bytes: [UInt8], path: String,
                                    options: Options) throws(ImportError) -> ImportedText? {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return nil }
        let utf8 = Array(xml)
        guard utf8.count <= options.maximumSize else {
            throw ImportError(path: path, reason: .tooLarge(limit: options.maximumSize))
        }
        let endings = utf8.withUnsafeBufferPointer { Detection.lineEndings($0) }
        return ImportedText(kind: .document, utf8: utf8, encoding: nil, lineEndings: endings,
                            documentFormat: .binaryPlist, byteCount: bytes.count, roundTrips: false)
    }
}
