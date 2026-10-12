// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol
import Security

/// Installs the `prism` command-line tool as a symbolic link from a `bin`
/// folder (normally `/usr/local/bin` or `~/bin`) to the copy inside the app.
///
/// Another program named `prism` (in the folder, or anywhere on the search
/// path) is never overwritten or shadowed silently: `install` reports it as
/// a conflict, and the caller may install Prism's tool as `prism-diff`
/// instead.
public struct CommandLineToolInstaller: Sendable {
    /// The tool's name, and the helper's name inside the app.
    public static let toolName = "prism"
    /// The link name used when another `prism` is present.
    public static let alternateName = "prism-diff"
    /// The code-signing identifier of Prism's tool (see scripts/bundle.sh).
    static let signingIdentifier = "\(PrismInfo.bundleIdentifier).tool"

    /// A program of another application found where the tool would go.
    public struct ForeignTool: Sendable, Equatable {
        public var path: URL
        /// `path` with symbolic links resolved.
        public var resolvedPath: URL
        /// The application bundle the program lives in, without `.app`.
        public var ownerName: String?
        /// Its code-signing identifier, when signed.
        public var signingIdentifier: String?

        public init(path: URL, resolvedPath: URL, ownerName: String?, signingIdentifier: String?) {
            self.path = path
            self.resolvedPath = resolvedPath
            self.ownerName = ownerName
            self.signingIdentifier = signingIdentifier
        }
    }

    public enum State: Sendable, Equatable {
        case notInstalled
        /// Prism's tool is linked, as `prism` or as `prism-diff`.
        case installed(URL)
        /// Another program has the name `prism` in the destination and
        /// Prism's tool is not installed.
        case foreign(ForeignTool)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Another program has the name; the caller may install as
        /// `alternateName` instead.
        case conflict(ForeignTool)
        case missingHelper(URL)
        case fileSystem(String)

        public var description: String {
            switch self {
            case .conflict(let tool): "\(tool.path.path) belongs to another application"
            case .missingHelper(let url): "the app has no \(url.path)"
            case .fileSystem(let message): message
            }
        }
    }

    /// Folder holding the tools inside the app (`Prism.app/Contents/Helpers`).
    public let helpersDirectory: URL
    /// Folder the links go into.
    public let destination: URL
    /// Folders searched for another `prism` (normally `$PATH`).
    public let searchPath: [URL]

    public init(helpersDirectory: URL, destination: URL, searchPath: [URL] = []) {
        self.helpersDirectory = helpersDirectory
        self.destination = destination
        self.searchPath = searchPath
    }

    /// The usual destinations: `/usr/local/bin` and `~/bin`.
    public static func standardDestinations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/usr/local/bin", isDirectory: true), home.appending(path: "bin", directoryHint: .isDirectory)]
    }

    /// The folders of a `PATH` value.
    public static func searchPath(from path: String?) -> [URL] {
        (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    /// Prism's tool inside the app.
    public var helper: URL {
        helpersDirectory.appending(path: Self.toolName, directoryHint: .notDirectory)
    }

    func link(_ name: String) -> URL {
        destination.appending(path: name, directoryHint: .notDirectory)
    }

    // MARK: - Inspection

    public func state() -> State {
        let plain = link(Self.toolName)
        let plainClass = classify(plain)
        if plainClass == .ours { return .installed(plain) }
        let alternate = link(Self.alternateName)
        if classify(alternate) == .ours { return .installed(alternate) }
        // A link to another or deleted copy of Prism is not installed: Install
        // re-points it at this app.
        if case .foreign(let foreign) = plainClass { return .foreign(foreign) }
        return .notInstalled
    }

    enum Classification: Equatable {
        case absent
        case ours
        /// Prism's tool from another copy of the app (an older build, or a
        /// copy that was moved or deleted): replaced by Install.
        case stale
        case foreign(ForeignTool)
    }

    /// Whether `url` is missing, Prism's tool (a link to this app's copy, or
    /// any program signed as Prism's tool, such as an older copy) or
    /// another program.
    func classify(_ url: URL) -> Classification {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .absent }
        let resolved = url.resolvingSymlinksInPath()
        if resolved.standardizedFileURL.path == helper.resolvingSymlinksInPath().standardizedFileURL.path {
            return .ours
        }
        let isLink = (info.st_mode & S_IFMT) == S_IFLNK
        // A dangling link: its target (often a deleted copy of Prism) is gone.
        if isLink, !FileManager.default.fileExists(atPath: resolved.path) {
            return .stale
        }
        let identifier = Self.signingIdentifier(of: resolved)
        if identifier == Self.signingIdentifier {
            // Prism's tool, but from another copy of the app.
            return isLink ? .stale : .ours
        }
        return .foreign(ForeignTool(
            path: url,
            resolvedPath: resolved,
            ownerName: Self.ownerName(of: resolved),
            signingIdentifier: identifier
        ))
    }

    /// The name of the innermost `.app` bundle containing `url`.
    static func ownerName(of url: URL) -> String? {
        url.pathComponents.last { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    /// The code-signing identifier of the program at `url`, if it is signed.
    static func signingIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }

    /// Another application's `prism`: the one in the destination, else
    /// the first one on the search path; nil when there is none.
    public func foreignTool() -> ForeignTool? {
        if case .foreign(let foreign) = classify(link(Self.toolName)) { return foreign }
        for folder in searchPath {
            let candidate = folder.appending(path: Self.toolName, directoryHint: .notDirectory)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            if case .foreign(let foreign) = classify(candidate) { return foreign }
        }
        return nil
    }

    /// Another application's `prism` that comes before the destination on
    /// the search path, so that typing `prism` would run it instead of
    /// Prism's; nil when none does.
    public func shadowing() -> ForeignTool? {
        for folder in searchPath {
            if folder.standardizedFileURL.path == destination.standardizedFileURL.path { return nil }
            let candidate = folder.appending(path: Self.toolName, directoryHint: .notDirectory)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            if case .foreign(let foreign) = classify(candidate) { return foreign }
            return nil      // Prism's own copy comes first
        }
        return nil
    }

    // MARK: - Changes

    /// Links the tool into the destination as `prism`, or as `prism-diff`
    /// when `alternate` is true, and returns the link. Never overwrites
    /// another program: without `alternate`, another `prism` in the
    /// destination or on the search path throws `.conflict`.
    @discardableResult
    public func install(alternate: Bool = false) throws(Failure) -> URL {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw .missingHelper(helper)
        }
        try createDestination()
        let url = link(alternate ? Self.alternateName : Self.toolName)
        if case .foreign(let other) = classify(url) { throw .conflict(other) }
        if !alternate, classify(url) == .absent, let other = foreignTool() { throw .conflict(other) }
        // Only one of the two names is Prism's at a time.
        try uninstall()
        try makeLink(url)
        return url
    }

    /// Removes Prism's links (under either name). Other programs are left
    /// alone.
    public func uninstall() throws(Failure) {
        for name in [Self.toolName, Self.alternateName] {
            let url = link(name)
            let kind = classify(url)
            guard kind == .ours || kind == .stale else { continue }
            guard unlink(url.path) == 0 else {
                throw .fileSystem("cannot remove \(url.path): \(String(cString: strerror(errno)))")
            }
        }
    }

    private func createDestination() throws(Failure) {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw .fileSystem("cannot create \(destination.path): \((error as NSError).localizedDescription)")
        }
    }

    private func makeLink(_ url: URL) throws(Failure) {
        var info = stat()
        if lstat(url.path, &info) == 0, unlink(url.path) != 0 {
            throw .fileSystem("cannot replace \(url.path): \(String(cString: strerror(errno)))")
        }
        guard symlink(helper.path, url.path) == 0 else {
            throw .fileSystem("cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}
