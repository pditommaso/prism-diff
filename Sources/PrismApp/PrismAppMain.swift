// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismProtocol

/// Entry point of the Prism application: a regular AppKit app built
/// without a nib, driven by `AppDelegate`.
@main
@MainActor
enum PrismAppMain {
    nonisolated static func versionLine() -> String {
        "\(PrismInfo.appName) \(PrismInfo.version) (\(PrismInfo.build))"
    }

    static func main() {
        // Headless entry points that never start the app: the version, as
        // shown in About, and the first-screen bench of the perf suite.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            print(versionLine())
            return
        }
        if arguments.first == FirstScreenBench.argument {
            PrismApplication.shared.setActivationPolicy(.prohibited)
            exit(FirstScreenBench.run(Array(arguments.dropFirst())))
        }
        // The subclass routes menu commands to the frontmost document
        // window while Prism runs in the background.
        let app = PrismApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        // NSApplication.delegate is weak; keep the delegate alive until run() returns.
        withExtendedLifetime(delegate) {}
    }
}
