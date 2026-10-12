// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import RegexBuilder

/// Product identity shared by the app, the CLIs and the build scripts.
///
/// `version` and `build` are generated at build time by Plugins/VersionPlugin:
/// `version` from the `VERSION` file at the repository root (the single
/// source of the version), `build` from `PRISM_BUILD_NUMBER` (default `1`).
public enum PrismInfo {
    public static let appName = "Prism"
    public static let bundleIdentifier = "io.github.pditommaso.prism"
    public static let urlScheme = "prism"
    public static let gitToolName = "prism"
    public static let socketFileName = "prism.sock"

    /// Location of the app's IPC socket for the given home directory:
    /// `<home>/Library/Application Support/Prism/prism.sock`.
    public static func socketURL(home: URL) -> URL {
        home.appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: socketFileName, directoryHint: .notDirectory)
    }

    /// True when `text` is a SemVer 2.0 version: MAJOR.MINOR.PATCH with
    /// optional `-prerelease` and `+build` suffixes.
    public static func isSemver(_ text: String) -> Bool {
        let core = /(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/
        let pre = /(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?/
        let meta = /(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?/
        return text.wholeMatch(of: Regex { core; pre; meta }) != nil
    }
}
