// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol

/// What `prism` needs from its surroundings; tests replace parts of it.
struct ClientContext: Sendable {
    var environment: [String: String]
    var workingDirectory: String
    /// The process on whose behalf `prism` runs (see `CallerDetection`).
    var caller: @Sendable () -> CallerInfo
    var launcher: AppLauncher
    var launchTimeout: Double = 20

    var socketPath: String { IPCEnvironment.socketPath(environment: environment) }

    static func standard() -> ClientContext {
        let environment = ProcessInfo.processInfo.environment
        let directory = FileManager.default.currentDirectoryPath
        return ClientContext(
            environment: environment,
            workingDirectory: directory,
            caller: { CallerDetection.caller(workingDirectory: directory) },
            launcher: .standard(environment: environment)
        )
    }
}

/// App-integration mode of `prism`: sends files to the Prism app. It
/// accepts the same options and exit statuses as ksdiff. `prism` runs it
/// for every first argument that is not an engine command (see
/// `PrismClientEntry`).
///
/// Exit statuses: 0 on success (the app has the files, the document was
/// closed after `--wait`, or a merge was saved with every conflict
/// resolved); 1 for usage errors, a request the app refused, a failed
/// launch, the app quitting during `--wait`, or a merge closed without
/// being resolved; 255 when talking to a running app fails. A failed write to standard output is also 1
/// (`writeFailureStatus`).
struct ClientCommand {
    static let name = "prism"

    /// Exit status when standard output fails: prism uses 1 for all errors.
    static let writeFailureStatus: Int32 = ClientStatus.failure

    static let usageLine = "usage: \(name) [-w | --wait | --no-wait] FILE ..."

    static let helpText = """
        Opening files in the \(PrismInfo.appName) app:

        \(usageLine)
               \(name) [OPTIONS] --partial-changeset [--UUID ID] [--relative-path PATH] FILE FILE
               \(name) [OPTIONS] --changeset --filelist [--relative-path PATH] FILE FILE ...
               \(name) --mark-changeset-as-closed ID
               \(name) [OPTIONS] --merge --output OUT [--base BASE] FILE FILE

        Opens the files in the \(PrismInfo.appName) app, starting it if needed. Two
        files open side by side; folders open as a folder comparison.

        Commands:
          --diff                 compare the files (the default)
          --partial-changeset    add one file pair to a changeset: pairs sent by the
                                 same git, hg or svn run share one window
          --changeset            open a whole changeset; each --filelist starts a
                                 pair, and two folders expand to every file in them
          --mark-changeset-as-closed ID
                                 stop adding pairs to the changeset named by --UUID
          --merge                merge the two files (A, then B) into --output,
                                 using --base as their common ancestor; always
                                 waits until the merge window is closed

        Options:
          -w, --wait             wait until the window or tab is closed (always
                                 for --merge)
          --no-wait              return as soon as the app has the files (default;
                                 not with --merge)
          --output OUT           --merge: where the merged text is saved (created
                                 when it is first saved)
          --base BASE            --merge: the version both files come from
          --label LABEL          window title
          --UUID ID              name the changeset instead of using the caller
          --relative-path PATH   row name of the pair in the changeset sidebar
          --file-status STATUS   added, removed or changed (default: from which
                                 side is missing; a missing side is /dev/null)
          --snapshot             after a FILE: copy it now, as its owner may delete it
          --no-snapshot          after a FILE: never copy it
          --                     the rest are files (--snapshot and --no-snapshot
                                 still apply to the file before them)
          --supports-capability NAME
                                 print YES or NO
          -h, --help             show this help and exit
          --version              print the version number and exit
          --short-version        print the version number and build number and exit

        Files in temporary folders are copied before \(name) returns, unless
        --no-snapshot follows them. A file named diff, sniff, merge3 or help
        must be written with a path, for example ./diff, or \(name) runs that
        engine command instead.

        Environment:
          \(IPCEnvironment.socketPathVariable)    socket of the app (default:
                               ~/Library/Application Support/\(PrismInfo.appName)/\(PrismInfo.socketFileName))
          \(IPCEnvironment.appPathVariable)       app bundle to start when it is not running

        Exit status: 0 on success, 1 on errors or when the app quits during
        --wait, 255 when communication with the app fails. A merge exits 0
        only when its result was saved with every conflict resolved, and 1
        otherwise, so git can trust it.

        git mergetool:
          git config --global mergetool.prism.cmd \\
            '\(name) --merge --output "$MERGED" --base "$BASE" -- "$LOCAL" --snapshot "$REMOTE" --snapshot'
          git config --global mergetool.prism.trustExitCode true
          git mergetool -t prism

        """

    static func run(
        _ args: [String],
        stdout: TextSink,
        stderr: TextSink,
        context makeContext: @autoclosure () -> ClientContext = .standard()
    ) -> Int32 {
        let action: ClientAction
        do {
            action = try ClientArguments.parse(args)
        } catch {
            // `svn diff --diff-cmd prism` passes svn's own options.
            let ctx = makeContext()
            let caller = ctx.caller()
            guard let native = NativeDialect.rewrite(args, tool: caller.tool),
                  let rewritten = try? ClientArguments.parse(native) else {
                return usageError(error.message, stderr: stderr)
            }
            return open(rewritten, caller: caller, context: ctx, stdout: stdout, stderr: stderr)
        }

        switch action {
        case .help:
            stdout.write(helpText)
            return ClientStatus.success
        case .version:
            stdout.write("\(PrismInfo.version)\n")
            return ClientStatus.success
        case .shortVersion:
            stdout.write("\(PrismInfo.version) (\(PrismInfo.build))\n")
            return ClientStatus.success
        case .supportsCapability(let name):
            stdout.write(ClientArguments.capabilities.contains(name) ? "YES\n" : "NO\n")
            return ClientStatus.success
        case .markChangesetClosed(let id):
            return markClosed(id, context: makeContext(), stderr: stderr)
        case .open:
            let ctx = makeContext()
            let caller = ctx.caller()
            // `P4DIFF=prism` passes two plain paths: one changeset row each.
            if let native = NativeDialect.rewrite(args, tool: caller.tool),
               let rewritten = try? ClientArguments.parse(native) {
                return open(rewritten, caller: caller, context: ctx, stdout: stdout, stderr: stderr)
            }
            return open(action, caller: caller, context: ctx, stdout: stdout, stderr: stderr)
        }
    }

    private static func open(
        _ action: ClientAction,
        caller: CallerInfo,
        context: ClientContext,
        stdout: TextSink,
        stderr: TextSink
    ) -> Int32 {
        guard case .open(let arguments) = action else { return ClientStatus.failure }
        let resolver = ClientResolver(
            workingDirectory: context.workingDirectory,
            temporaryRule: TemporaryFileRule(environment: context.environment)
        )
        let invocation: Invocation
        do {
            invocation = try resolver.invocation(for: arguments, caller: caller)
        } catch {
            return usageError(error.message, stderr: stderr)
        }

        let session = ClientSession(
            client: IPCClient(socketPath: context.socketPath),
            launcher: context.launcher,
            launchTimeout: context.launchTimeout
        )
        let reply: Reply
        let connection: IPCClient.Connection?
        do {
            (reply, connection) = try session.send(
                Request(operation: .open, invocation: invocation), keepOpen: invocation.wait)
        } catch {
            return report(error, stderr: stderr)
        }
        guard reply.ok, reply.documentID != nil else {
            connection?.close()
            stderr.write("\(name): \(reply.error ?? "\(PrismInfo.appName) refused the request")\n")
            return ClientStatus.failure
        }
        context.launcher.activate?()
        guard invocation.wait, let connection else { return ClientStatus.success }
        switch ClientSession.waitForClose(connection, appPID: reply.serverPID) {
        case .documentClosed, .mergeResolved:
            return ClientStatus.success
        case .mergeUnresolved:
            return ClientStatus.failure
        case .appQuit:
            stderr.write("\(name): \(PrismInfo.appName) quit before the comparison was closed\n")
            return ClientStatus.failure
        }
    }

    private static func markClosed(_ id: String, context: ClientContext, stderr: TextSink) -> Int32 {
        let client = IPCClient(socketPath: context.socketPath)
        do {
            let (reply, _) = try client.send(Request(operation: .markChangesetClosed, changesetUUID: id))
            guard reply.ok else {
                stderr.write("\(name): \(reply.error ?? "request refused")\n")
                return ClientStatus.failure
            }
            return ClientStatus.success
        } catch .notRunning {
            // Nothing is open, so there is nothing to close.
            return ClientStatus.success
        } catch {
            return report(.communication(error.description), stderr: stderr)
        }
    }

    private static func report(_ failure: ClientSession.Failure, stderr: TextSink) -> Int32 {
        switch failure {
        case .failed(let message):
            stderr.write("\(name): \(message)\n")
            return ClientStatus.failure
        case .communication(let message):
            stderr.write("\(name): cannot communicate with \(PrismInfo.appName): \(message)\n")
            return ClientStatus.communicationError
        }
    }

    private static func usageError(_ problem: String, stderr: TextSink) -> Int32 {
        stderr.write("""
            \(name): \(problem)
            \(usageLine)
            try '\(name) --help' for more information

            """)
        return ClientStatus.failure
    }
}

/// What the `prism` executable needs from app-integration mode.
public enum PrismClientEntry {
    /// Exit status when standard output fails in this mode.
    public static let writeFailureStatus = ClientCommand.writeFailureStatus

    /// The app-integration part of `prism --help`.
    public static let helpText = ClientCommand.helpText

    /// Parses `args` (everything after the program name) and talks to the app.
    public static func run(_ args: [String], stdout: TextSink, stderr: TextSink) -> Int32 {
        ClientCommand.run(args, stdout: stdout, stderr: stderr)
    }
}
