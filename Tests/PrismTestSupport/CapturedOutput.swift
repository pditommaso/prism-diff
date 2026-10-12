// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol

/// Collects text written to a `TextSink` so tests can inspect it.
public final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    public init() {}

    /// Everything written so far.
    public var text: String {
        lock.withLock { buffer }
    }

    /// A sink that appends to this capture.
    public var sink: TextSink {
        TextSink { [self] chunk in
            lock.withLock { buffer += chunk }
        }
    }
}
