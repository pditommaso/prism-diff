// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Locates the shared test corpus in `Tests/corpus` of the source checkout.
public enum Corpus {
    /// The repository root: the nearest ancestor of this source file that
    /// contains `Package.swift`.
    public static let root: URL = findRoot(startingAt: URL(filePath: #filePath))

    /// `Tests/corpus` inside the repository.
    public static var directory: URL {
        root.appending(path: "Tests/corpus", directoryHint: .isDirectory)
    }

    /// `Tests/corpus/golden`, where expected outputs live.
    public static var goldenDirectory: URL {
        directory.appending(path: "golden", directoryHint: .isDirectory)
    }

    /// `Tests/corpus/generated`, where `generate.py` writes large inputs.
    public static var generatedDirectory: URL {
        directory.appending(path: "generated", directoryHint: .isDirectory)
    }

    /// A committed fixture, for example `fixture("text/a.swift")`.
    public static func fixture(_ relative: String) -> URL {
        directory.appending(path: "fixtures", directoryHint: .isDirectory)
            .appending(path: relative, directoryHint: .notDirectory)
    }

    /// Walks up from `start` to the first directory holding `Package.swift`.
    static func findRoot(startingAt start: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = start.deletingLastPathComponent()
        while candidate.path(percentEncoded: false) != "/" {
            let manifest = candidate.appending(path: "Package.swift", directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: manifest.path(percentEncoded: false)) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        fatalError("Package.swift not found above \(start.path(percentEncoded: false))")
    }
}
