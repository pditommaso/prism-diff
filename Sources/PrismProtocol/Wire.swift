// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

// Messages exchanged between `prism` and the Prism app over the local
// socket. Each message is one JSON object in one length-prefixed frame (see
// `Framing`). A connection carries one `Request`, answered by one `Reply`;
// when the request asked to wait, the app later sends one `Event` on the same
// connection and closes it.
//
// Field names are part of the protocol: rename them only together with a
// `IPCProtocol.version` bump.

/// Version of the message format. The app refuses requests whose version
/// differs, so an old `prism` and a new app never misread each other.
public enum IPCProtocol {
    public static let version = 1
    /// Path of a side that does not exist (an added or removed file).
    public static let placeholderPath = "/dev/null"
}

/// How a file pair changed, as shown by the status glyph in a changeset.
public enum FileStatus: String, Codable, Sendable, CaseIterable {
    case changed
    case added
    case removed
}

/// One file named on the command line, resolved by `prism`.
public struct FileReference: Codable, Sendable, Hashable {
    /// Absolute path, or `IPCProtocol.placeholderPath` for a missing side.
    public var path: String
    /// True when the file lives somewhere its owner may delete as soon as
    /// `prism` returns; the app copies such files before replying.
    public var temporary: Bool

    public init(path: String, temporary: Bool) {
        self.path = path
        self.temporary = temporary
    }

    public var isPlaceholder: Bool { path == IPCProtocol.placeholderPath }
}

/// The files of one comparison: two for a pair, more for a file shelf.
public struct FileList: Codable, Sendable, Hashable {
    public var files: [FileReference]
    public var status: FileStatus
    /// Path shown in a changeset sidebar, relative to the repository root.
    public var relativePath: String?

    public init(files: [FileReference], status: FileStatus = .changed, relativePath: String? = nil) {
        self.files = files
        self.status = status
        self.relativePath = relativePath
    }
}

/// What the caller asked for.
public enum InvocationKind: String, Codable, Sendable {
    /// Plain `prism A B`: a new comparison.
    case diff
    /// One file pair of a changeset that arrives one pair per call
    /// (`git difftool`); calls with the same group key share a window.
    case partialChangeset
    /// A whole changeset in one call (`--changeset --filelist ...`).
    case changeset
    /// A three-way merge (`--merge --output OUT [--base BASE] A B`): the
    /// file list holds A, B and, when given, the base; the result goes to
    /// `Invocation.mergeOutput`.
    case merge
}

/// The version-control tool that ran `prism`, when one was found.
public enum VersionControlTool: String, Codable, Sendable {
    case git
    case mercurial
    case subversion
    case perforce
    case bazaar
    case unknown
}

/// A process identified by its PID and start time, so that a recycled PID
/// is never mistaken for the original process.
public struct ProcessIdentity: Codable, Sendable, Hashable {
    public var pid: Int32
    public var startSeconds: Int64
    public var startMicroseconds: Int32

    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int32) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    /// Changeset grouping key: `PID:<pid>-<seconds>.<microseconds>`.
    public var groupKey: String { "PID:\(pid)-\(startSeconds).\(startMicroseconds)" }
}

/// The process on whose behalf `prism` runs: the nearest version-control
/// ancestor, or the immediate parent when there is none.
public struct CallerInfo: Codable, Sendable, Hashable {
    public var process: ProcessIdentity?
    /// Short process name, such as `git`.
    public var name: String
    /// The caller's argument vector, when it could be read.
    public var arguments: [String]
    public var tool: VersionControlTool
    /// `prism`'s working directory, which it inherits from the caller.
    public var workingDirectory: String

    public init(
        process: ProcessIdentity?,
        name: String,
        arguments: [String],
        tool: VersionControlTool,
        workingDirectory: String
    ) {
        self.process = process
        self.name = name
        self.arguments = arguments
        self.tool = tool
        self.workingDirectory = workingDirectory
    }
}

/// One `prism` request to open files.
public struct Invocation: Codable, Sendable, Hashable {
    public var kind: InvocationKind
    public var fileLists: [FileList]
    /// Window title chosen with `--label`.
    public var label: String?
    /// Explicit changeset identifier (`--UUID`), instead of the caller's
    /// process.
    public var changesetUUID: String?
    /// True when `prism` blocks until the document closes.
    public var wait: Bool
    public var caller: CallerInfo
    public var clientPID: Int32
    /// Absolute path the merged text is saved to (`--output`); only for
    /// `.merge`. Optional on the wire, so older messages still decode.
    public var mergeOutput: String?

    public init(
        kind: InvocationKind,
        fileLists: [FileList],
        label: String? = nil,
        changesetUUID: String? = nil,
        wait: Bool = false,
        caller: CallerInfo,
        clientPID: Int32 = getpid(),
        mergeOutput: String? = nil
    ) {
        self.kind = kind
        self.fileLists = fileLists
        self.label = label
        self.changesetUUID = changesetUUID
        self.wait = wait
        self.caller = caller
        self.clientPID = clientPID
        self.mergeOutput = mergeOutput
    }

    /// The key that decides which changeset a partial changeset joins:
    /// `UUID:<uuid>` when one was given, otherwise the caller's process key.
    public var groupKey: String? {
        if let changesetUUID { return Self.uuidKey(changesetUUID) }
        return caller.process?.groupKey
    }

    public static func uuidKey(_ uuid: String) -> String { "UUID:\(uuid)" }
}

/// Operations the app answers.
public enum IPCOperation: String, Codable, Sendable {
    /// Liveness check; the reply carries the app's PID.
    case ping
    /// Open or extend a document (`invocation` is required).
    case open
    /// Stop adding files to a changeset (`changesetUUID` is required).
    case markChangesetClosed
    /// List the open documents (used by tests and diagnostics).
    case status
}

public struct Request: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var operation: IPCOperation
    public var invocation: Invocation?
    public var changesetUUID: String?

    public init(
        operation: IPCOperation,
        invocation: Invocation? = nil,
        changesetUUID: String? = nil,
        protocolVersion: Int = IPCProtocol.version
    ) {
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.invocation = invocation
        self.changesetUUID = changesetUUID
    }
}

/// A document as listed by the `status` operation.
public struct DocumentSummary: Codable, Sendable, Hashable {
    public var id: String
    public var kind: InvocationKind
    public var title: String
    public var groupKey: String?
    public var relativePaths: [String]
    /// False while a changeset may still receive files.
    public var isComplete: Bool
    public var isClosed: Bool

    public init(
        id: String,
        kind: InvocationKind,
        title: String,
        groupKey: String?,
        relativePaths: [String],
        isComplete: Bool,
        isClosed: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.groupKey = groupKey
        self.relativePaths = relativePaths
        self.isComplete = isComplete
        self.isClosed = isClosed
    }
}

public struct Reply: Codable, Sendable, Hashable {
    public var ok: Bool
    public var error: String?
    /// The document that received the files (`open`).
    public var documentID: String?
    /// The app's PID, so that a waiting `prism` can watch it.
    public var serverPID: Int32
    public var documents: [DocumentSummary]?

    public init(
        ok: Bool,
        error: String? = nil,
        documentID: String? = nil,
        serverPID: Int32 = getpid(),
        documents: [DocumentSummary]? = nil
    ) {
        self.ok = ok
        self.error = error
        self.documentID = documentID
        self.serverPID = serverPID
        self.documents = documents
    }

    public static func failure(_ message: String) -> Reply {
        Reply(ok: false, error: message)
    }
}

public enum EventKind: String, Codable, Sendable {
    /// The user closed the document a waiting `prism` asked for.
    case documentClosed
    /// A merge document closed after its result was saved with every
    /// conflict resolved (`prism --merge` exits 0).
    case mergeResolved
    /// A merge document closed any other way (`prism --merge` exits 1).
    case mergeUnresolved
}

public struct Event: Codable, Sendable, Hashable {
    public var kind: EventKind
    public var documentID: String

    public init(kind: EventKind, documentID: String) {
        self.kind = kind
        self.documentID = documentID
    }
}

/// JSON coding shared by both ends.
public enum WireCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
