// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import PrismProtocol

/// `prism diff`: compares two files and prints the differences.
///
/// Exit status, as diff(1): 0 when the files compare equal, 1 when they
/// differ, 2 for usage errors and unreadable inputs (and, through
/// `PrismMain`, when standard output cannot be written).
struct DiffCommand {

    enum Format: String {
        case unified = "--unified"
        case sideBySide = "--side-by-side"
        case json = "--json"
    }

    /// Side-by-side width when neither `--width` nor `$COLUMNS` gives one.
    static let defaultWidth = 160
    /// Narrowest accepted `--width`.
    static let minimumWidth = 20
    /// Widest accepted `--width`; every row is padded to the width, so an
    /// unbounded value would allocate without limit.
    static let maximumWidth = 4096

    var whitespace = WhitespaceMode.exact
    var format = Format.unified
    var color = false
    var width: Int?
    var paths: [String] = []

    static func usageLine(_ name: String) -> String {
        "usage: \(name) diff [--ws 0|1|2] [--json | --unified | --side-by-side] [--color] [--width N] A B"
    }

    static func helpText(_ name: String) -> String {
        """
        \(name) diff - compare two text files line by line and word by word

        \(usageLine(name))

        Output (choose at most one):
          --unified        unified format with 3 lines of context (default)
          --side-by-side   A and B in two columns, with line numbers and a
                           marker between them: '<' deleted, '>' inserted,
                           '|' changed
          --json           the differences as a JSON document (format
                           "prism-diff", version 1)

        Options:
          --ws MODE        whitespace handling: 0 compares every byte (default),
                           1 ignores line-ending differences (LF, CRLF, CR),
                           2 also ignores spaces and tabs at line edges
          --color          colour the output with ANSI escapes: green for
                           inserted lines, red for deleted lines, yellow for
                           changed lines, changed words in reverse video
                           (ignored with --json)
          --width N        total width of the side-by-side view, from
                           \(minimumWidth) to \(maximumWidth) (default: $COLUMNS, else \(defaultWidth))
          -h, --help       show this help and exit

        Each file is decoded first: its encoding (UTF-8, UTF-16, UTF-32,
        Latin-1, Shift JIS, ...) and byte order mark are detected, and the
        text of RTF, DOC, DOCX, ODT and PDF documents is extracted. The
        decoded text is compared and shown as UTF-8; line endings are kept.
        Binary files are refused. /dev/null reads as an empty file. Pipes
        and process substitution work; '-' reads standard input (for one of
        the two files only). '\(name) sniff FILE' shows how a file is read.

        Exit status: 0 if the files compare equal, 1 if they differ,
        2 on a usage error, a binary or unreadable file or a failed write.

        """
    }

    /// Parses the arguments after `diff`. Returns nil and writes nothing
    /// when help was requested; throws a usage message otherwise.
    static func parse(_ args: [String]) throws(UsageError) -> DiffCommand? {
        var command = DiffCommand()
        var formatFlag: String?
        var reader = ArgumentReader(args)
        while let arg = reader.next() {
            if reader.isOperand {
                command.paths.append(arg)
                continue
            }
            switch arg {
            case "-h", "--help":
                return nil
            case "--json", "--unified", "--side-by-side":
                if let previous = formatFlag, previous != arg {
                    throw UsageError("'\(previous)' and '\(arg)' cannot be combined")
                }
                formatFlag = arg
                command.format = Format(rawValue: arg)!
            case "--color":
                command.color = true
            default:
                if let value = try reader.value(for: "--ws", in: arg) {
                    guard let mode = Int(value).flatMap(WhitespaceMode.init(rawValue:)) else {
                        throw UsageError("'--ws' takes 0, 1 or 2, not '\(value)'")
                    }
                    command.whitespace = mode
                } else if let value = try reader.value(for: "--width", in: arg) {
                    guard let width = Int(value), (minimumWidth ... maximumWidth).contains(width) else {
                        throw UsageError("'--width' takes a number of columns from \(minimumWidth) to \(maximumWidth), not '\(value)'")
                    }
                    command.width = width
                } else {
                    throw UsageError("unrecognised option '\(arg)'")
                }
            }
        }
        guard command.paths.count == 2 else {
            throw UsageError(command.paths.count < 2 ? "two files are needed" : "too many files given")
        }
        try checkStandardInput(command.paths)
        return command
    }

    static func run(_ args: [String], programName name: String, environment: [String: String],
                    stdout: TextSink, stderr: TextSink) -> Int32 {
        let command: DiffCommand
        do {
            guard let parsed = try parse(args) else {
                stdout.write(helpText(name))
                return 0
            }
            command = parsed
        } catch {
            return error.report(command: "\(name) diff", usage: usageLine(name), stderr: stderr)
        }
        return command.execute(programName: name, environment: environment, stdout: stdout, stderr: stderr)
    }

    func execute(programName name: String, environment: [String: String],
                 stdout: TextSink, stderr: TextSink) -> Int32 {
        var texts: [[UInt8]] = []
        do throws(FileInput.Failure) {
            for path in paths {
                let imported = try TextInput.read(path)
                guard imported.isText else {
                    throw FileInput.Failure(path: path, message: TextInput.binaryMessage)
                }
                texts.append(imported.utf8)
            }
        } catch {
            stderr.write("\(name) diff: \(error.path): \(error.message)\n")
            return 2
        }
        let a = texts[0], b = texts[1]
        let result = TextDiff.diff(a, b, options: DiffOptions(whitespace: whitespace))
        let palette = Palette(enabled: color)
        var out = ChunkedOutput(stdout)
        switch format {
        case .json:
            JSONWriter.write(result, a: a, b: b, whitespace: whitespace, to: &out)
        case .unified:
            UnifiedRenderer.write(result, a: a, b: b, labelA: paths[0], labelB: paths[1],
                                  palette: palette, to: &out)
        case .sideBySide:
            let renderer = SideBySideRenderer(width: effectiveWidth(environment), palette: palette)
            renderer.write(result, a: a, b: b, to: &out)
        }
        out.flush()
        return result.isIdentical ? 0 : 1
    }

    /// `--width`, else a usable `$COLUMNS`, else the default.
    func effectiveWidth(_ environment: [String: String]) -> Int {
        if let width { return width }
        if let columns = environment["COLUMNS"].flatMap({ Int($0) }),
           (Self.minimumWidth ... Self.maximumWidth).contains(columns) {
            return columns
        }
        return Self.defaultWidth
    }
}

/// Standard input can be read only once, so at most one operand may be `-`.
func checkStandardInput(_ paths: [String]) throws(UsageError) {
    if paths.filter({ $0 == FileInput.standardInputName }).count > 1 {
        throw UsageError("standard input ('-') can be given only once")
    }
}

/// A command-line mistake, reported with the command's usage line.
struct UsageError: Error, Equatable {
    let reason: String

    init(_ reason: String) { self.reason = reason }

    /// Writes "<command>: <reason>", the usage line and a pointer to the
    /// help, and returns the usage-error status, 2.
    func report(command: String, usage: String, stderr: TextSink) -> Int32 {
        stderr.write("""
            \(command): \(reason)
            \(usage)
            try '\(command) --help' for more information

            """)
        return 2
    }
}

/// Walks a subcommand's arguments. Options may come before, between or
/// after the operands; `--` ends the options, and so does nothing else.
/// A lone `-` is an operand.
struct ArgumentReader {
    private let args: [String]
    private var index = 0
    private var optionsEnded = false
    /// True when the argument just returned by `next()` is an operand.
    private(set) var isOperand = false

    init(_ args: [String]) { self.args = args }

    mutating func next() -> String? {
        while index < args.count {
            let arg = args[index]
            index += 1
            if !optionsEnded && arg == "--" {
                optionsEnded = true
                continue
            }
            isOperand = optionsEnded || arg == "-" || !arg.hasPrefix("-")
            return arg
        }
        return nil
    }

    /// The value of option `name` when `arg` is that option, either as
    /// `name=value` or as `name` followed by the next argument; nil when
    /// `arg` is another option.
    mutating func value(for name: String, in arg: String) throws(UsageError) -> String? {
        if arg == name {
            guard index < args.count else { throw UsageError("'\(name)' needs a value") }
            index += 1
            return args[index - 1]
        }
        if arg.hasPrefix(name + "=") {
            return String(arg.dropFirst(name.count + 1))
        }
        return nil
    }
}
