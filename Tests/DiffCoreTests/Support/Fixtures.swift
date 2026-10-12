// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCheck
import DiffCore
import Foundation
import PrismTestSupport

/// Helpers shared by the DiffCore tests.
enum Fixtures {
    /// The bytes of a committed corpus fixture.
    static func bytes(_ relative: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: Corpus.fixture(relative)))
    }

    /// The non-equal blocks of a result.
    static func differences(_ result: TextDiffResult) -> [DiffBlock] {
        result.blocks.filter { $0.kind != .equal }
    }
}

extension String {
    var bytes: [UInt8] { Array(utf8) }
}
