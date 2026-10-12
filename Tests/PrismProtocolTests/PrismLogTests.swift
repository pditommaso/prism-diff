// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol
import PrismTestSupport
import Testing

@Suite struct PrismLogTests {
    @Test func categoriesAndSubsystem() {
        #expect(PrismLog.subsystem == PrismInfo.bundleIdentifier)
        #expect(PrismLog.categories == ["diff", "import", "folder", "ipc", "merge", "ui"])
        // Logging must never fail or block, whatever the category.
        for logger in [PrismLog.diff, PrismLog.import, PrismLog.folder, PrismLog.ipc, PrismLog.merge, PrismLog.ui] {
            logger.debug("PrismLogTests: \(1, privacy: .public)")
        }
    }

    /// Diagnostics go through os.Logger (PrismLog), never NSLog or print to
    /// the console from the app and its libraries.
    @Test func noAdHocLoggingInTheApp() throws {
        let sources = Corpus.root.appending(path: "Sources", directoryHint: .isDirectory)
        var offenders: [String] = []
        for module in ["PrismApp", "PrismIntegration", "FolderCore", "TextImport", "PrismProtocol"] {
            let folder = sources.appending(path: module, directoryHint: .isDirectory)
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("NSLog(") { offenders.append(file.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "NSLog in \(offenders)")
    }
}
