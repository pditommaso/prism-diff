// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol

@main
enum PrismMain {
    static func main() {
        let arguments = CommandLine.arguments
        let name = PrismCommand.programName(fromArgv0: arguments.first)
        let args = Array(arguments.dropFirst())
        let status = PrismCommand.run(
            args,
            programName: name,
            environment: ProcessInfo.processInfo.environment,
            stdout: .standardOutput,
            stderr: .standardError
        )
        // Output that never reached the reader is "trouble", as in diff(1).
        exit(TextSink.exitStatus(
            status,
            stdout: .standardOutput,
            stderr: .standardError,
            program: name,
            writeFailureStatus: PrismCommand.writeFailureStatus(for: args)
        ))
    }
}
