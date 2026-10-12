// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol

/// Text shown in the About window, derived from `PrismInfo`.
struct AboutContent: Equatable, Sendable {
    var title: String
    var versionLine: String
    var licenseLine: String
    var disclaimer: String
    var sourceURL: URL

    /// The non-affiliation notice, word for word the same in About, Help
    /// and the README.
    static let nonAffiliation = "Prism is an independent open-source project, not affiliated with Kaleidoscope. "
        + "The prism command accepts the same options as ksdiff for compatibility."

    static let current = AboutContent(
        title: PrismInfo.appName,
        versionLine: "Version \(PrismInfo.version) (\(PrismInfo.build))",
        licenseLine: "Licensed under the Apache License 2.0",
        disclaimer: nonAffiliation,
        sourceURL: URL(string: "https://github.com/pditommaso/prism-diff")!
    )
}
