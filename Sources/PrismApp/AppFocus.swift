// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// Brings Prism to the front, except under the acceptance scripts
/// (`PRISM_TESTING=1`), which must never take the focus from the user.
@MainActor
enum AppFocus {
    static let isTesting = ProcessInfo.processInfo.environment["PRISM_TESTING"] == "1"

    static func activate() {
        if !isTesting { NSApp.activate() }
    }
}
