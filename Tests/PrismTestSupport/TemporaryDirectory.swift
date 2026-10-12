// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// A uniquely named scratch directory under the system temporary directory.
/// Call `remove()` when done; tests never touch the real home directory.
public struct TemporaryDirectory: Sendable {
    public let url: URL

    public init(prefix: String = "prism-test") throws {
        let name = "\(prefix)-\(UUID().uuidString)"
        url = FileManager.default.temporaryDirectory
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
