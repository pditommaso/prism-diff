// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import os

/// Unified-logging categories of the subsystem `io.github.pditommaso.prism`.
/// View them with:
///
///     log stream --predicate 'subsystem == "io.github.pditommaso.prism"'
///     log show --last 1h --predicate 'subsystem == "io.github.pditommaso.prism" && category == "ipc"'
///
/// Paths and user text are logged as private unless they are already
/// public (such as a message about Prism's own socket). Nothing is sent
/// anywhere: there is no crash or usage reporting.
public enum PrismLog {
    public static let subsystem = PrismInfo.bundleIdentifier
    /// Comparisons that fail to load or re-diff.
    public static let diff = Logger(subsystem: subsystem, category: "diff")
    /// Files that cannot be read or decoded as text.
    public static let `import` = Logger(subsystem: subsystem, category: "import")
    /// Folder scans, live refresh and copies.
    public static let folder = Logger(subsystem: subsystem, category: "folder")
    /// The prism socket, changesets and the integration installers.
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    /// Three-way merges and their saves.
    public static let merge = Logger(subsystem: subsystem, category: "merge")
    /// Windows, settings, themes and saving edited files.
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Every category name, in a stable order.
    public static let categories = ["diff", "import", "folder", "ipc", "merge", "ui"]
}
