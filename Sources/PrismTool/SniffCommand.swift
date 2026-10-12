// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol
import TextImport

/// `prism sniff`: reports how files would be read for comparison.
///
/// Exit status: 0 when every file was classified (binary, missing and
/// folder are classifications, not errors), 2 for usage errors, unreadable
/// files, files that are too large or documents that fail to convert.
struct SniffCommand {
    var json = false
    var paths: [String] = []

    static func usageLine(_ name: String) -> String {
        "usage: \(name) sniff [--json] FILE ..."
    }

    static func helpText(_ name: String) -> String {
        """
        \(name) sniff - report how files would be read for comparison

        \(usageLine(name))

        For each file, prints its kind (text, document, binary, directory or
        missing), the detected encoding and byte order mark, the line
        endings (lf, crlf, cr, mixed or none), the number of lines, whether
        the last line ends with a newline, the size in bytes, and whether
        the text can be written back byte for byte in its encoding.
        Documents (RTF, DOC, DOCX, ODT, PDF, ...) also report their format.

        Options:
          --json       one JSON object per file and line instead of the
                       "key: value" report
          -h, --help   show this help and exit

        '-' reads standard input (once).

        Exit status: 0 when every file was classified, 2 on a usage error,
        an unreadable or oversized file, or a failed write.

        """
    }

    static func parse(_ args: [String]) throws(UsageError) -> SniffCommand? {
        var command = SniffCommand()
        var reader = ArgumentReader(args)
        while let arg = reader.next() {
            if reader.isOperand {
                command.paths.append(arg)
                continue
            }
            switch arg {
            case "-h", "--help": return nil
            case "--json": command.json = true
            default: throw UsageError("unrecognised option '\(arg)'")
            }
        }
        guard !command.paths.isEmpty else { throw UsageError("no file given") }
        try checkStandardInput(command.paths)
        return command
    }

    static func run(_ args: [String], programName name: String, stdout: TextSink, stderr: TextSink) -> Int32 {
        let command: SniffCommand
        do {
            guard let parsed = try parse(args) else {
                stdout.write(helpText(name))
                return 0
            }
            command = parsed
        } catch {
            return error.report(command: "\(name) sniff", usage: usageLine(name), stderr: stderr)
        }
        return command.execute(programName: name, stdout: stdout, stderr: stderr)
    }

    func execute(programName name: String, stdout: TextSink, stderr: TextSink) -> Int32 {
        var status: Int32 = 0
        var first = true
        for path in paths {
            let imported: ImportedText
            do {
                imported = try Self.importFile(path)
            } catch {
                stderr.write("\(name) sniff: \(error.path): \(error.message)\n")
                status = 2
                continue
            }
            let fields = Self.fields(path: path, imported)
            if json {
                stdout.write(Self.json(fields))
            } else {
                stdout.write((first ? "" : "\n") + fields.map { "\($0.key): \($0.value.text)" }.joined(separator: "\n") + "\n")
            }
            first = false
        }
        return status
    }

    /// `TextImport.load` for paths, so folders and missing paths are
    /// classified; `FileInput` for standard input.
    static func importFile(_ path: String) throws(FileInput.Failure) -> ImportedText {
        if path == FileInput.standardInputName { return try TextInput.read(path) }
        do {
            return try TextImport.load(URL(filePath: path))
        } catch {
            throw FileInput.Failure(path: path, message: error.message)
        }
    }

    enum Value {
        case string(String), number(Int), bool(Bool)

        var text: String {
            switch self {
            case .string(let s): s
            case .number(let n): String(n)
            case .bool(let b): b ? "yes" : "no"
            }
        }

        var json: String {
            switch self {
            case .string(let s): SniffCommand.quote(s)
            case .number(let n): String(n)
            case .bool(let b): b ? "true" : "false"
            }
        }
    }

    /// The report of one file, in a fixed order.
    static func fields(path: String, _ imported: ImportedText) -> [(key: String, value: Value)] {
        var fields: [(key: String, value: Value)] = [("file", .string(path)), ("kind", .string(imported.kind.rawValue))]
        if let format = imported.documentFormat { fields.append(("format", .string(format.rawValue))) }
        if let encoding = imported.encoding {
            fields.append(("encoding", .string(encoding.name)))
            fields.append(("bom", .bool(imported.hasBOM)))
        }
        if imported.isText {
            let endings = imported.lineEndings
            fields.append(("line-endings", .string(endings.style.rawValue)))
            fields.append(("lines", .number(endings.lineCount(byteCount: imported.utf8.count))))
            fields.append(("final-newline", .bool(endings.hasFinalNewline)))
        }
        if imported.kind != .missing && imported.kind != .directory {
            fields.append(("bytes", .number(imported.byteCount)))
        }
        if imported.kind == .text { fields.append(("round-trip", .bool(imported.roundTrips))) }
        return fields
    }

    static func json(_ fields: [(key: String, value: Value)]) -> String {
        "{" + fields.map { "\(quote($0.key)):\($0.value.json)" }.joined(separator: ",") + "}\n"
    }

    /// A JSON string literal.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
