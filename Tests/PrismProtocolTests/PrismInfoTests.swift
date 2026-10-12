// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismProtocol
import PrismTestSupport

@Suite struct PrismInfoTests {
    @Test func versionIsSemver() {
        #expect(PrismInfo.isSemver(PrismInfo.version))
    }

    /// Plugins/VersionPlugin compiles the VERSION file into PrismInfo.version.
    @Test func versionComesFromTheVersionFile() throws {
        let file = Corpus.root.appending(path: "VERSION", directoryHint: .notDirectory)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(PrismInfo.version == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The build number comes from PRISM_BUILD_NUMBER (default 1): numeric.
    @Test func buildIsNumeric() {
        #expect(PrismInfo.build.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil)
    }

    @Test func identity() {
        #expect(PrismInfo.appName == "Prism")
        #expect(PrismInfo.bundleIdentifier == "io.github.pditommaso.prism")
        #expect(PrismInfo.gitToolName == "prism")
        #expect(!PrismInfo.build.isEmpty)
    }

    @Test func urlSchemeIsPrism() {
        #expect(PrismInfo.urlScheme == "prism")
        #expect(PrismInfo.urlScheme != "diff")
    }

    @Test func socketURLLivesUnderApplicationSupport() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let socket = PrismInfo.socketURL(home: home.url)
        #expect(socket.path(percentEncoded: false)
            .hasSuffix("Library/Application Support/Prism/prism.sock"))
        #expect(socket.path(percentEncoded: false)
            .hasPrefix(home.url.path(percentEncoded: false)))
        #expect(socket.lastPathComponent == PrismInfo.socketFileName)
    }

    @Test(arguments: ["0.1.0", "1.2.3", "10.20.30", "1.0.0-alpha", "1.0.0-rc.1+build.5", "2.0.0+meta", "0.2.0-rc.1"])
    func acceptsValidSemver(_ text: String) {
        #expect(PrismInfo.isSemver(text))
    }

    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "01.2.3", "v1.2.3", "1.2.3-", "1.2.3 ", "a.b.c", "1.2.3-.", "1.2.3+", "1.2.3-a..b"])
    func rejectsInvalidSemver(_ text: String) {
        #expect(!PrismInfo.isSemver(text))
    }
}
