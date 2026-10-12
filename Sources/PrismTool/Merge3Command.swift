// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore
import PrismProtocol

/// `prism merge3`: merges two edited versions of a file with their common
/// base.
///
/// Exit status: 0 when every difference was merged automatically, 1 when at
/// least one conflict remains, 2 for usage errors and unreadable inputs
/// (and, through `PrismMain`, when standard output cannot be written).
struct Merge3Command {
    var whitespace = WhitespaceMode.exact
    var json = false
    var paths: [String] = []

    static func usageLine(_ name: String) -> String {
        "usage: \(name) merge3 [--ws 0|1|2] [--json] BASE A B"
    }

    static func helpText(_ name: String) -> String {
        """
        \(name) merge3 - merge two edited versions of a file with their common base

        \(usageLine(name))

        A and B both started from BASE. Where only one of them changed a
        region, that change is taken; where both changed it differently, the
        region is a conflict and the merged text leaves it out.

        Options:
          --json       print the merge as a JSON document (format
                       "prism-merge3", version 1): every region, the
                       conflict counts and the merged text
          --ws MODE    whitespace handling: 0 compares every byte (default),
                       1 ignores line-ending differences (LF, CRLF, CR),
                       2 also ignores spaces and tabs at line edges
          -h, --help   show this help and exit

        Without --json a short summary of the differences is printed.
        Files are decoded as by '\(name) diff' (encodings, documents);
        binary files are refused. Pipes and process substitution work; '-'
        reads standard input (for one of the three files only).

        Exit status: 0 if there are no conflicts, 1 if there are,
        2 on a usage error, a binary or unreadable file or a failed write.

        """
    }

    static func parse(_ args: [String]) throws(UsageError) -> Merge3Command? {
        var command = Merge3Command()
        var reader = ArgumentReader(args)
        while let arg = reader.next() {
            if reader.isOperand {
                command.paths.append(arg)
                continue
            }
            switch arg {
            case "-h", "--help":
                return nil
            case "--json":
                command.json = true
            default:
                guard let value = try reader.value(for: "--ws", in: arg) else {
                    throw UsageError("unrecognised option '\(arg)'")
                }
                guard let mode = Int(value).flatMap(WhitespaceMode.init(rawValue:)) else {
                    throw UsageError("'--ws' takes 0, 1 or 2, not '\(value)'")
                }
                command.whitespace = mode
            }
        }
        guard command.paths.count == 3 else {
            throw UsageError(command.paths.count < 3 ? "three files are needed: BASE, A and B" : "too many files given")
        }
        try checkStandardInput(command.paths)
        return command
    }

    static func run(_ args: [String], programName name: String, stdout: TextSink, stderr: TextSink) -> Int32 {
        let command: Merge3Command
        do {
            guard let parsed = try parse(args) else {
                stdout.write(helpText(name))
                return 0
            }
            command = parsed
        } catch {
            return error.report(command: "\(name) merge3", usage: usageLine(name), stderr: stderr)
        }
        return command.execute(programName: name, stdout: stdout, stderr: stderr)
    }

    func execute(programName name: String, stdout: TextSink, stderr: TextSink) -> Int32 {
        var inputs: [[UInt8]] = []
        do throws(FileInput.Failure) {
            for path in paths {
                let imported = try TextInput.read(path)
                guard imported.isText else {
                    throw FileInput.Failure(path: path, message: TextInput.binaryMessage)
                }
                inputs.append(imported.utf8)
            }
        } catch {
            stderr.write("\(name) merge3: \(error.path): \(error.message)\n")
            return 2
        }
        let result: Merge3Result
        do {
            result = try Merge3.merge(base: inputs[0], a: inputs[1], b: inputs[2],
                                      options: DiffOptions(whitespace: whitespace))
        } catch .tooLarge {
            stderr.write("\(name) merge3: the files are too large to merge (the limit is 2 GiB for BASE, and for A and B together)\n")
            return 2
        } catch {
            // Nothing cancels this merge; kept so a future token is handled.
            stderr.write("\(name) merge3: the merge was cancelled\n")
            return 2
        }
        var out = ChunkedOutput(stdout)
        out.append(json ? result.json : Self.summary(result))
        out.flush()
        return result.unresolvedConflictCount > 0 ? 1 : 0
    }

    /// One line per region where A and B differ, then the totals.
    static func summary(_ result: Merge3Result) -> String {
        var text = ""
        for region in result.differences {
            let lines = "A \(describe(region.aRange)), B \(describe(region.bRange))"
            switch region.kind {
            case .conflict:
                text += "conflict: \(lines); base \(describe(region.baseRange))\n"
            default:
                text += "merged (took \(region.choice.name)): \(lines)\n"
            }
        }
        let differences = result.differences.count
        text += "\(differences) difference\(differences == 1 ? "" : "s"), "
        text += "\(result.conflictCount) conflict\(result.conflictCount == 1 ? "" : "s")\n"
        return text
    }

    /// A 0-based half-open line range in 1-based words.
    static func describe(_ range: Range<Int>) -> String {
        switch range.count {
        case 0: "no lines (after line \(range.lowerBound))"
        case 1: "line \(range.lowerBound + 1)"
        default: "lines \(range.lowerBound + 1)-\(range.upperBound)"
        }
    }
}
