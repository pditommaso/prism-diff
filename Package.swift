// swift-tools-version:6.0
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import MachO
import PackageDescription

// The Swift 6.4 Command Line Tools ship the swift-testing macro plugin in a
// directory that `swift test` does not add to the compiler's plugin search
// path. From a clean .build this fails deterministically with "plugin for
// module 'TestingMacros' not found".
//
// The flag must name the plugin of the toolchain that is actually building,
// never another one installed on the same machine (Xcode and the CLT often
// coexist, e.g. on CI runners, and their plugin versions are independent).
// The manifest runs linked against the building toolchain's
// libPackageDescription, so its loaded path identifies that toolchain:
// <toolchain>/usr/lib/swift/pm/ManifestAPI/libPackageDescription.dylib.
// The flag is added only when that toolchain has the plugin directory,
// which is the CLT layout; Xcode finds its plugin unaided.
// unsafeFlags are allowed because this is the root package.
func buildingToolchainRoot() -> String? {
    let suffix = "/usr/lib/swift/pm/ManifestAPI/libPackageDescription.dylib"
    for index in 0..<_dyld_image_count() {
        guard let raw = _dyld_get_image_name(index) else { continue }
        let path = String(cString: raw)
        if path.hasSuffix(suffix) {
            return String(path.dropLast(suffix.count))
        }
    }
    return nil
}

let testSwiftSettings: [SwiftSetting] = {
    guard let root = buildingToolchainRoot() else { return [] }
    let plugins = root + "/usr/lib/swift/host/plugins/testing"
    guard FileManager.default.fileExists(atPath: plugins) else { return [] }
    return [.unsafeFlags(["-plugin-path", plugins])]
}()

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiffCore", targets: ["DiffCore"]),
        .library(name: "TextImport", targets: ["TextImport"]),
        .library(name: "FolderCore", targets: ["FolderCore"]),
        .library(name: "PrismProtocol", targets: ["PrismProtocol"]),
        .executable(name: "prism", targets: ["PrismTool"]),
        // Not named "Prism": it would collide with "prism" on a
        // case-insensitive file system. bundle.sh renames it in the app.
        .executable(name: "PrismApp", targets: ["PrismApp"]),
    ],
    targets: [
        // Pure Swift diff engine. Imports only Darwin and Dispatch, never
        // Foundation, and takes no unsafe flags.
        .target(name: "DiffCore", exclude: ["README.md"]),
        // Seeded case generator and invariant checker for the diff engine,
        // shared by the unit tests and the release-mode bench. Not a product.
        .target(name: "DiffCheck", dependencies: ["DiffCore"]),
        .target(name: "TextImport", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("PDFKit")]),
        .target(name: "FolderCore", linkerSettings: [.linkedFramework("CoreServices")]),
        .target(name: "PrismProtocol", plugins: ["VersionPlugin"]),
        // Generates PrismInfo.version (from VERSION) and PrismInfo.build (from
        // PRISM_BUILD_NUMBER, default 1) into PrismProtocol on every build.
        .plugin(name: "VersionPlugin", capability: .buildTool()),
        // The app end of the prism socket, changeset routing, snapshots and
        // the CLI / git integration installers. No AppKit: the app plugs in
        // its windows through DocumentSink.
        .target(name: "PrismIntegration", dependencies: ["PrismProtocol"]),
        // Headless stand-in for the app's socket server, for the acceptance
        // scripts and git difftool tests. Internal: never bundled.
        .executableTarget(name: "PrismIPCStub", dependencies: ["PrismProtocol", "PrismIntegration", "DiffCore"]),
        // App-integration mode of `prism` (ksdiff-compatible options): talks
        // to the app over its socket. A library linked into PrismTool.
        .target(name: "PrismClient", dependencies: ["PrismProtocol"], linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(name: "PrismTool", dependencies: ["PrismProtocol", "PrismClient", "DiffCore", "TextImport"]),
        // Release-mode bench and cross-checks (perf budgets, property run,
        // cancel latency, git --patience hunk counts). Internal: not a
        // declared product, and scripts/bundle.sh never copies it into the app.
        .executableTarget(name: "PrismBench", dependencies: ["DiffCore", "DiffCheck", "FolderCore"]),
        .executableTarget(
            name: "PrismApp",
            dependencies: ["PrismProtocol", "DiffCore", "TextImport", "PrismIntegration", "FolderCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Test-only: hides windows that unit tests put on screen.
        .target(name: "PrismTestWindowGuard", path: "Tests/PrismTestWindowGuard",
                linkerSettings: [.linkedFramework("AppKit")]),
        // Shared helpers for test targets only: temp dirs, output capture,
        // corpus lookup and the golden-file harness.
        .target(name: "PrismTestSupport", dependencies: ["PrismProtocol", "PrismTestWindowGuard"], path: "Tests/PrismTestSupport",
                swiftSettings: testSwiftSettings),

        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore", "DiffCheck", "PrismTestSupport"], swiftSettings: testSwiftSettings),
        .testTarget(name: "TextImportTests", dependencies: ["TextImport", "PrismTestSupport"], swiftSettings: testSwiftSettings),
        .testTarget(name: "FolderCoreTests", dependencies: ["FolderCore", "PrismTestSupport"], swiftSettings: testSwiftSettings),
        .testTarget(name: "PrismProtocolTests", dependencies: ["PrismProtocol", "PrismTestSupport"], swiftSettings: testSwiftSettings),
        .testTarget(name: "PrismClientTests", dependencies: ["PrismClient", "PrismProtocol", "PrismIntegration", "PrismTestSupport"], swiftSettings: testSwiftSettings),
        .testTarget(name: "PrismIntegrationTests", dependencies: ["PrismIntegration", "PrismProtocol", "PrismTestSupport"], swiftSettings: testSwiftSettings),
        .testTarget(name: "PrismToolTests", dependencies: ["PrismTool", "PrismClient", "DiffCore", "PrismProtocol", "TextImport", "PrismTestSupport"], swiftSettings: testSwiftSettings),
        .testTarget(name: "PrismAppTests", dependencies: ["PrismApp", "PrismProtocol", "DiffCore", "PrismIntegration", "FolderCore", "PrismTestSupport"], swiftSettings: testSwiftSettings),
    ]
)
