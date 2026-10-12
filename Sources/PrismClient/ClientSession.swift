// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import Foundation
import os
import PrismProtocol

/// Exit statuses of `prism`.
enum ClientStatus {
    static let success: Int32 = 0
    /// Usage and request errors, a launch failure, or the app quitting while
    /// `prism` waits.
    static let failure: Int32 = 1
    /// Talking to the app failed after it was reached (exit(-1)).
    static let communicationError: Int32 = 255
}

/// Starts the app when nothing listens on the socket.
struct AppLauncher: Sendable {
    let launch: @Sendable () throws -> Void
    /// Brings the app to the front once it has opened the comparison.
    var activate: (@Sendable () -> Void)? = nil

    /// Launches the app with `/usr/bin/open` in the background, passing the
    /// environment the app needs: `PRISM_LAUNCHED_BY_CLI` (so that it opens
    /// no window of its own) and the documented variables that are set
    /// (`IPCEnvironment.forwardedVariables`: `PRISM_SOCKET_PATH` above all).
    ///
    /// The app is, in order: `$PRISM_APP_PATH`; the bundle `prism` itself
    /// lives in (`Prism.app/Contents/Helpers/prism`, symlinks resolved);
    /// otherwise whatever Launch Services knows under the bundle identifier.
    static func standard(environment: [String: String]) -> AppLauncher {
        AppLauncher(launch: {
            var args = ["-g"]
            if let app = appBundle(environment: environment) {
                args += ["-a", app]
            } else {
                args += ["-b", PrismInfo.bundleIdentifier]
            }
            args += ["--env", "\(IPCEnvironment.launchedByCLIVariable)=\(getpid())"]
            for (name, value) in forwardedEnvironment(environment) {
                args += ["--env", "\(name)=\(value)"]
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw LaunchError(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }, activate: { bringToFront(environment: environment) })
    }

    /// Asks Launch Services to bring the app forward. The request comes from
    /// the command line the user just ran, so macOS honours it, whereas the
    /// app activating itself while the terminal is in front is refused
    /// (cooperative activation). Skipped when the app is already in front
    /// (each file of a git difftool run calls `prism`) and under tests.
    static func bringToFront(environment: [String: String]) {
        if environment[IPCEnvironment.testingVariable] == "1" { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PrismInfo.bundleIdentifier { return }
        var args: [String] = []
        if let app = appBundle(environment: environment) {
            args += ["-a", app]
        } else {
            args += ["-b", PrismInfo.bundleIdentifier]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    struct LaunchError: Error, CustomStringConvertible {
        let message: String
        var description: String { message.isEmpty ? "open failed" : message }
    }

    /// The documented variables (`IPCEnvironment.forwardedVariables`)
    /// passed on to a launched app, sorted by name.
    static func forwardedEnvironment(_ environment: [String: String]) -> [(String, String)] {
        environment.filter { name, value in
            IPCEnvironment.forwardedVariables.contains(name) && !value.isEmpty
        }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    static func appBundle(environment: [String: String]) -> String? {
        if let path = environment[IPCEnvironment.appPathVariable], !path.isEmpty {
            return path
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app.path : nil
    }
}

/// Sends requests to the app, launching it when needed, and waits for
/// documents to close.
struct ClientSession: Sendable {
    let client: IPCClient
    let launcher: AppLauncher
    /// How long to wait for a launched app to answer.
    var launchTimeout: Double = 20

    enum Failure: Error {
        /// Reported with exit status 1.
        case failed(String)
        /// Reported with exit status 255.
        case communication(String)
    }

    /// Sends `request`, launching the app first if it is not running.
    func send(_ request: Request, keepOpen: Bool) throws(Failure) -> (Reply, IPCClient.Connection?) {
        do {
            return try client.send(request, keepOpen: keepOpen)
        } catch .notRunning {
            try launchAndWait()
        } catch {
            throw .communication(error.description)
        }
        do {
            return try client.send(request, keepOpen: keepOpen)
        } catch {
            throw .communication(error.description)
        }
    }

    private func launchAndWait() throws(Failure) {
        do {
            try launcher.launch()
        } catch {
            throw .failed("cannot launch \(PrismInfo.appName): \(error)")
        }
        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            if client.isServerRunning(timeout: 1) { return }
            usleep(10_000)
        }
        throw .failed("\(PrismInfo.appName) did not start within \(Int(launchTimeout)) seconds")
    }

    enum WaitOutcome: Equatable {
        case documentClosed
        /// A merge was saved with every conflict resolved.
        case mergeResolved
        /// A merge was closed without being resolved.
        case mergeUnresolved
        case appQuit
    }

    /// Blocks until the app reports the document closed, or the app quits:
    /// either the connection ends or a kqueue process watch on `appPID`
    /// fires, whichever comes first.
    static func waitForClose(_ connection: IPCClient.Connection, appPID: Int32) -> WaitOutcome {
        let outcome = OSAllocatedUnfairLock<WaitOutcome?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let finish: @Sendable (WaitOutcome) -> Void = { result in
            let first = outcome.withLock { current -> Bool in
                guard current == nil else { return false }
                current = result
                return true
            }
            if first { done.signal() }
        }

        // An in-process server (tests) has no process of its own to watch.
        var watch: DispatchSourceProcess?
        if appPID != getpid() {
            let source = DispatchSource.makeProcessSource(
                identifier: appPID, eventMask: .exit, queue: .global(qos: .userInitiated))
            source.setEventHandler { finish(.appQuit) }
            source.resume()
            watch = source
            if kill(appPID, 0) != 0 && errno == ESRCH { finish(.appQuit) }
        }
        let reader = Thread {
            switch (try? connection.waitForEvent())?.kind {
            case .documentClosed: finish(.documentClosed)
            case .mergeResolved: finish(.mergeResolved)
            case .mergeUnresolved: finish(.mergeUnresolved)
            case nil: finish(.appQuit)
            }
        }
        reader.start()
        done.wait()
        watch?.cancel()
        connection.close()
        return outcome.withLock { $0 } ?? .appQuit
    }
}
