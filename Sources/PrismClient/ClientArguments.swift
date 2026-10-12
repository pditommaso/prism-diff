// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import PrismProtocol

/// A file named on the command line, before it is resolved.
struct ParsedFile: Equatable {
    var path: String
    /// `--snapshot` (true) or `--no-snapshot` (false) after the file; nil
    /// lets the temporary-file rule decide.
    var snapshot: Bool?
}

/// The files of one comparison, before they are resolved.
struct ParsedFileList: Equatable {
    var files: [ParsedFile] = []
    var relativePath: String?
    var status: FileStatus?

    var isEmpty: Bool { files.isEmpty && relativePath == nil && status == nil }
}

/// A request to open files, as parsed.
struct OpenArguments: Equatable {
    var kind: InvocationKind = .diff
    /// nil when neither `--wait` nor `--no-wait` was given.
    var wait: Bool?
    var label: String?
    var changesetUUID: String?
    var fileLists: [ParsedFileList] = [ParsedFileList()]
    /// `--output` of a merge, as given.
    var output: String?
    /// `--base` of a merge, as given.
    var base: ParsedFile?

    /// A merge always waits for its window to close (`--no-wait` is
    /// refused); every other command returns at once unless told to wait.
    var waits: Bool { wait ?? (kind == .merge) }
}

/// What the command line asks `prism` to do.
enum ClientAction: Equatable {
    case help
    case version
    case shortVersion
    case supportsCapability(String)
    case markChangesetClosed(String)
    case open(OpenArguments)
}

/// A command-line error: printed with the usage line, exit status 1.
struct UsageError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The `prism` grammar:
///
///     prism --version | --short-version | -h | --help
///     prism --supports-capability CAPABILITY
///     prism [OPTIONS] [--diff] FILE [FILE ...]
///     prism [OPTIONS] --partial-changeset [--UUID ID] [--relative-path PATH] FILE FILE
///     prism [OPTIONS] --changeset (--filelist [--relative-path PATH] [--file-status S] FILE FILE)...
///     prism --mark-changeset-as-closed ID
///     prism [OPTIONS] --merge --output OUT [--base BASE] FILE FILE
///
///     OPTIONS: -w | --wait | --no-wait, --label LABEL
///     after a FILE: --snapshot | --no-snapshot
///
/// `--name=value` is the same as `--name value` before `--`. After `--`
/// every argument is a file, except `--snapshot` and `--no-snapshot`, which
/// still apply to the file before them: git's usual mergetool command puts
/// them there. Before `--`, they may also follow `--base BASE`.
enum ClientArguments {
    static let capabilities: Set<String> = ["diffs-v1", "changesets-v1", "partial-changesets-v1", "merges-v1"]

    static let waitOptions = ["-w", "--wait", "--no-wait"]
    static let commandOptions = ["--diff", "--partial-changeset", "--changeset", "--merge"]
    static let informationalOptions: Set<String> = ["-h", "--help", "--version"]
    static let fileOptions: Set<String> = ["--snapshot", "--no-snapshot"]
    static let valueOptions: Set<String> = [
        "--label", "--UUID", "--relative-path", "--file-status",
        "--supports-capability", "--mark-changeset-as-closed",
    ]

    /// Splits `--name=value` into two arguments, up to the first `--`.
    static func tokenize(_ args: [String]) -> [String] {
        var out: [String] = []
        var optionsEnded = false
        for arg in args {
            if arg == "--" { optionsEnded = true }
            if !optionsEnded, arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                out.append(String(arg[..<equals]))
                out.append(String(arg[arg.index(after: equals)...]))
            } else {
                out.append(arg)
            }
        }
        return out
    }

    static func parse(_ rawArgs: [String]) throws(UsageError) -> ClientAction {
        // Answered before anything else, whatever follows: the app runs
        // `prism --short-version` to compare the installed tool's version.
        if rawArgs.first == "--short-version" { return .shortVersion }
        let args = tokenize(rawArgs)
        guard !args.isEmpty else { throw UsageError("no files given") }

        var open = OpenArguments()
        var commandSeen: String?
        var waitSeen: [String] = []
        var informational: String?
        var capability: String?
        var closeID: String?
        var optionsEnded = false
        var index = 0
        /// The last file named was `--base`'s (so a file option applies to it).
        var lastWasBase = false

        func value(for option: String) throws(UsageError) -> String {
            index += 1
            guard index < args.count else { throw UsageError("'\(option)' needs a value") }
            return args[index]
        }
        func currentList() -> Int { open.fileLists.count - 1 }

        while index < args.count {
            let arg = args[index]
            defer { index += 1 }

            if fileOptions.contains(arg), lastWasBase, var base = open.base {
                if base.snapshot != nil {
                    throw UsageError("use at most one of --snapshot, --no-snapshot per file")
                }
                base.snapshot = (arg == "--snapshot")
                open.base = base
                continue
            }
            lastWasBase = false
            if fileOptions.contains(arg) {
                let list = currentList()
                guard let last = open.fileLists[list].files.indices.last else {
                    throw UsageError("'\(arg)' must follow a file")
                }
                if open.fileLists[list].files[last].snapshot != nil {
                    throw UsageError("use at most one of --snapshot, --no-snapshot per file")
                }
                open.fileLists[list].files[last].snapshot = (arg == "--snapshot")
                continue
            }
            if optionsEnded || !arg.hasPrefix("-") || arg == "-" {
                open.fileLists[currentList()].files.append(ParsedFile(path: arg, snapshot: nil))
                continue
            }
            switch arg {
            case "--":
                optionsEnded = true
            case _ where informationalOptions.contains(arg) || arg == "--short-version":
                if informational == nil { informational = arg }
            case _ where waitOptions.contains(arg):
                waitSeen.append(arg)
            case _ where commandOptions.contains(arg):
                if let commandSeen, commandSeen != arg {
                    throw UsageError("use at most one of \(commandOptions.joined(separator: ", "))")
                }
                commandSeen = arg
                open.kind = switch arg {
                case "--partial-changeset": .partialChangeset
                case "--changeset": .changeset
                case "--merge": .merge
                default: .diff
                }
            case "--output":
                if open.output != nil { throw UsageError("'--output' given twice") }
                open.output = try value(for: arg)
            case "--base":
                if open.base != nil { throw UsageError("'--base' given twice") }
                open.base = ParsedFile(path: try value(for: arg), snapshot: nil)
                lastWasBase = true
            case "--label":
                open.label = try value(for: arg)
            case "--UUID":
                open.changesetUUID = try value(for: arg)
            case "--relative-path":
                let path = try value(for: arg)
                if open.fileLists[currentList()].relativePath != nil {
                    throw UsageError("'--relative-path' given twice for the same file list")
                }
                open.fileLists[currentList()].relativePath = path
            case "--file-status":
                let raw = try value(for: arg)
                guard let status = FileStatus(rawValue: raw) else {
                    throw UsageError("'--file-status' must be added, removed or changed, not '\(raw)'")
                }
                if open.fileLists[currentList()].status != nil {
                    throw UsageError("'--file-status' given twice for the same file list")
                }
                open.fileLists[currentList()].status = status
            case "--filelist":
                if !open.fileLists[currentList()].isEmpty {
                    open.fileLists.append(ParsedFileList())
                }
            case "--supports-capability":
                capability = try value(for: arg)
            case "--mark-changeset-as-closed":
                closeID = try value(for: arg)
            default:
                throw UsageError("unrecognised option '\(arg)'")
            }
        }

        if waitSeen.count > 1 {
            let distinct = waitSeen.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let problem = distinct.count == 1
                ? "'\(distinct[0])' given more than once"
                : distinct.map { "'\($0)'" }.joined(separator: " and ") + " conflict"
            throw UsageError("\(problem): use at most one of \(waitOptions.joined(separator: ", "))")
        }
        if let first = waitSeen.first { open.wait = first != "--no-wait" }

        if let option = informational {
            guard rawArgs.count == 1 else { throw UsageError("'\(option)' must be used on its own") }
            switch option {
            case "--version": return .version
            case "--short-version": return .shortVersion
            default: return .help
            }
        }
        if let capability {
            guard args.count == 2 else { throw UsageError("'--supports-capability' must be used on its own") }
            return .supportsCapability(capability)
        }
        if let closeID {
            guard args.count == 2 else { throw UsageError("'--mark-changeset-as-closed' must be used on its own") }
            return .markChangesetClosed(closeID)
        }

        open.fileLists.removeAll { $0.isEmpty }
        try validate(open, explicitCommand: commandSeen != nil)
        return .open(open)
    }

    private static func validate(_ open: OpenArguments, explicitCommand: Bool) throws(UsageError) {
        let lists = open.fileLists
        guard !lists.isEmpty, lists.contains(where: { !$0.files.isEmpty }) else {
            throw UsageError("no files given")
        }
        if open.changesetUUID != nil, open.kind != .partialChangeset {
            throw UsageError("'--UUID' needs --partial-changeset")
        }
        if open.kind != .merge {
            if open.output != nil { throw UsageError("'--output' needs --merge") }
            if open.base != nil { throw UsageError("'--base' needs --merge") }
        }
        switch open.kind {
        case .diff:
            if lists.count > 1 { throw UsageError("'--filelist' needs --changeset") }
            if lists[0].relativePath != nil { throw UsageError("'--relative-path' needs --partial-changeset or --changeset") }
            if lists[0].status != nil { throw UsageError("'--file-status' needs --partial-changeset or --changeset") }
        case .partialChangeset:
            if lists.count > 1 { throw UsageError("'--filelist' needs --changeset") }
            guard lists[0].files.count == 2 else {
                throw UsageError("--partial-changeset needs exactly two files, got \(lists[0].files.count)")
            }
        case .changeset:
            for list in lists where list.files.count != 2 {
                throw UsageError("each --filelist needs exactly two files, got \(list.files.count)")
            }
        case .merge:
            guard let output = open.output, !output.isEmpty else {
                throw UsageError("a merge needs an --output path for the result")
            }
            if lists.count > 1 { throw UsageError("'--filelist' needs --changeset") }
            if lists[0].relativePath != nil { throw UsageError("'--relative-path' needs --partial-changeset or --changeset") }
            if lists[0].status != nil { throw UsageError("'--file-status' needs --partial-changeset or --changeset") }
            guard lists[0].files.count == 2 else {
                throw UsageError("--merge needs exactly two files, got \(lists[0].files.count)")
            }
            // Its exit status reports how the merge ended, so it must wait.
            if open.wait == false { throw UsageError("'--no-wait' cannot be used with --merge, which waits for the result") }
        }
        for list in lists {
            let paths = list.files.map(\.path).filter { $0 != IPCProtocol.placeholderPath }
            if Set(paths).count != paths.count {
                throw UsageError("the same file appears twice in one comparison")
            }
        }
    }
}

/// Argument vectors that version-control tools pass when `prism` is set as
/// their external diff program without `prism` options.
enum NativeDialect {
    /// Rewrites `args` into `prism` options when the caller is a tool with a
    /// known calling convention; returns nil otherwise.
    static func rewrite(_ args: [String], tool: VersionControlTool) -> [String]? {
        switch tool {
        case .subversion: return subversion(args)
        case .perforce: return perforce(args)
        default: return nil
        }
    }

    /// `svn diff --diff-cmd prism` runs `prism -u -L "<path>\t(rev)" -L
    /// "<path>\t(rev)" LEFT RIGHT`. The label's path part becomes the
    /// changeset row.
    static func subversion(_ args: [String]) -> [String]? {
        guard args.count >= 4, args.first == "-u" || args.first == "-L", args.contains("-L") else { return nil }
        var labels: [String] = []
        var files: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-L", index + 1 < args.count {
                labels.append(args[index + 1])
                index += 2
                continue
            }
            if arg != "-u" { files.append(arg) }
            index += 1
        }
        guard files.count == 2 else { return nil }
        let label = labels.last ?? labels.first ?? ""
        let path = label.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
        var out = ["--partial-changeset"]
        if !path.isEmpty { out += ["--relative-path", path] }
        return out + ["--", files[0], files[1]]
    }

    /// `P4DIFF=prism` runs `prism LEFT RIGHT`.
    static func perforce(_ args: [String]) -> [String]? {
        guard args.count == 2, !args.contains(where: { $0.hasPrefix("-") }) else { return nil }
        return ["--partial-changeset", "--", args[0], args[1]]
    }
}
