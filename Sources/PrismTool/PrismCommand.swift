// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import PrismClient
import PrismProtocol

/// Argument handling for `prism`.
///
/// The first argument picks the mode: `diff`, `merge3`, `sniff`, `help`,
/// `-h`, `--help` and `--version` (or no argument) run the headless engine
/// tools; anything else (paths, or ksdiff-compatible options such as
/// `--partial-changeset` and `--merge`) opens the files in the app (see
/// `PrismClientEntry`). A file with an engine command's name must be given
/// as a path, such as `./diff`. The tool may be installed under
/// another name (for example `prism-diff`), so messages use the name it was
/// invoked as.
///
/// Exit codes follow diff(1): 0 for `--help` and `--version`; each command
/// documents its own 0 and 1; 2 (`usageErrorStatus`) for any usage error;
/// 2 (`writeFailureStatus`) when standard output could not be written.
struct PrismCommand {
    static let defaultName = "prism"

    /// Exit status for a usage error, matching diff(1) "trouble".
    static let usageErrorStatus: Int32 = 2

    /// Exit status when standard output fails, matching diff(1) "trouble".
    static let writeFailureStatus: Int32 = 2

    /// Subcommands that work, with a one-line summary.
    static let subcommands: [(name: String, summary: String)] = [
        ("diff", "compare two text files and print the differences"),
        ("merge3", "combine two edited versions of a file with their common base"),
        ("sniff", "report how a file would be read (kind, encoding, line endings)"),
    ]

    /// First arguments that select the headless engine tools; any other
    /// first argument selects app-integration mode.
    static let engineArguments: Set<String> = ["diff", "merge3", "sniff", "help", "-h", "--help", "--version"]

    /// True when `args` run the engine tools rather than open the app.
    static func isEngineInvocation(_ args: [String]) -> Bool {
        guard let first = args.first else { return true }
        return engineArguments.contains(first)
    }

    /// Exit status for a failed write to standard output in the mode `args`
    /// select.
    static func writeFailureStatus(for args: [String]) -> Int32 {
        isEngineInvocation(args) ? writeFailureStatus : PrismClientEntry.writeFailureStatus
    }

    /// Subcommands planned for later milestones, with a one-line summary.
    static let plannedSubcommands: [(name: String, summary: String)] = []

    /// The program name to show in messages: the last path component of
    /// `argv0`, or `prism` when it is missing or empty.
    static func programName(fromArgv0 argv0: String?) -> String {
        guard let argv0, let last = argv0.split(separator: "/").last, !last.isEmpty else {
            return defaultName
        }
        return String(last)
    }

    static func usageLine(_ name: String) -> String {
        "usage: \(name) [--help | --version] COMMAND [ARGS ...]\n       \(name) [OPTIONS] FILE ..."
    }

    static func helpText(_ name: String) -> String {
        var text = """
            \(name) - compare files with \(PrismInfo.appName), in the app or headless

            \(usageLine(name))

            Options:
              -h, --help    show this help and exit
              --version     print the version number and exit

            Commands:

            """
        let width = (subcommands + plannedSubcommands).map(\.name.count).max() ?? 0
        func list(_ commands: [(name: String, summary: String)]) {
            for command in commands {
                let pad = String(repeating: " ", count: width - command.name.count)
                text += "  \(command.name)\(pad)    \(command.summary)\n"
            }
        }
        list(subcommands)
        if !plannedSubcommands.isEmpty {
            text += "\nNot yet available:\n"
            list(plannedSubcommands)
        }
        text += """

            Run '\(name) COMMAND --help' for the options of a command.

            Exit status of the commands: 0 on success (no differences, no
            conflicts), 1 when differences or conflicts were found, 2 on a usage
            error or other trouble, such as an unreadable file or a failed write.

            Any other first argument opens the files in the app instead.

            """
        text += "\n" + PrismClientEntry.helpText
        return text
    }

    /// Runs the tool. `environment` supplies `COLUMNS` for side-by-side
    /// output; tests leave it empty. `client` handles app-integration mode;
    /// tests replace it so that they never reach a real app.
    static func run(
        _ args: [String],
        programName name: String = defaultName,
        environment: [String: String] = [:],
        stdout: TextSink,
        stderr: TextSink,
        client: ([String], TextSink, TextSink) -> Int32 = PrismClientEntry.run
    ) -> Int32 {
        guard isEngineInvocation(args) else {
            return client(args, stdout, stderr)
        }
        guard let first = args.first else {
            return usageError("no command given", name: name, stderr: stderr)
        }
        let informational = ["--version", "-h", "--help", "help"]
        if informational.contains(first) {
            guard args.count == 1 else {
                return usageError("'\(first)' takes no arguments", name: name, stderr: stderr)
            }
            stdout.write(first == "--version" ? "\(PrismInfo.version)\n" : helpText(name))
            return 0
        }
        let rest = Array(args.dropFirst())
        switch first {
        case "diff":
            return DiffCommand.run(rest, programName: name, environment: environment,
                                   stdout: stdout, stderr: stderr)
        case "merge3":
            return Merge3Command.run(rest, programName: name, stdout: stdout, stderr: stderr)
        case "sniff":
            return SniffCommand.run(rest, programName: name, stdout: stdout, stderr: stderr)
        default:
            break
        }
        if plannedSubcommands.contains(where: { $0.name == first }) {
            return usageError("command '\(first)' is not yet available", name: name, stderr: stderr)
        }
        return usageError("unknown command '\(first)'", name: name, stderr: stderr)
    }

    private static func usageError(_ reason: String, name: String, stderr: TextSink) -> Int32 {
        stderr.write("""
            \(name): \(reason)
            \(usageLine(name))
            try '\(name) --help' for more information

            """)
        return usageErrorStatus
    }
}
