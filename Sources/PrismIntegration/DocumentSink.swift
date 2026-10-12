// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import os
import PrismProtocol

/// One side of a comparison, ready to be read by the app.
public struct ComparisonFile: Sendable, Hashable {
    /// The path `prism` sent, or `/dev/null` for a missing side.
    public var originalPath: String
    /// The file to read: the snapshot copy when one was made, otherwise the
    /// original path.
    public var path: String
    /// True when `path` is a private copy of a temporary file. Its folder
    /// means nothing to the user, so only the file name is shown.
    public var isSnapshot: Bool

    public init(originalPath: String, path: String, isSnapshot: Bool) {
        self.originalPath = originalPath
        self.path = path
        self.isSnapshot = isSnapshot
    }

    public var isPlaceholder: Bool { originalPath == IPCProtocol.placeholderPath }

    /// The file name of the original path.
    public var fileName: String { (originalPath as NSString).lastPathComponent }
}

/// One row of a changeset, or the single comparison of a plain diff.
public struct ChangesetEntry: Sendable, Hashable {
    public var relativePath: String
    public var status: FileStatus
    /// Two files for a pair; more for a file shelf.
    public var files: [ComparisonFile]

    public init(relativePath: String, status: FileStatus, files: [ComparisonFile]) {
        self.relativePath = relativePath
        self.status = status
        self.files = files
    }
}

/// A document the app should show.
public struct DocumentContent: Sendable, Hashable {
    public var id: String
    public var kind: InvocationKind
    /// The `--label`, or for a changeset the suggested title
    /// ("Changes in <folder>"); nil for a plain diff without a label.
    public var title: String?
    public var tool: VersionControlTool
    public var entries: [ChangesetEntry]
    /// False while more pairs may arrive (a partial changeset whose caller
    /// is still running).
    public var isComplete: Bool
    /// A merge's `--output` path (its one entry holds A, B and the base,
    /// when there is one); nil for other documents.
    public var mergeOutput: String?

    public init(
        id: String,
        kind: InvocationKind,
        title: String?,
        tool: VersionControlTool,
        entries: [ChangesetEntry],
        isComplete: Bool,
        mergeOutput: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.tool = tool
        self.entries = entries
        self.isComplete = isComplete
        self.mergeOutput = mergeOutput
    }
}

/// Where the router delivers documents: the app's window layer, or a
/// recording fake in tests. Methods are called on the router's private
/// queue, in order; implementations hop to their own thread as needed.
public protocol DocumentSink: AnyObject, Sendable {
    /// Show a new document.
    func open(_ document: DocumentContent)
    /// Add rows to a changeset that is already shown.
    func append(_ entries: [ChangesetEntry], toDocument id: String)
    /// No more rows will arrive for this changeset.
    func complete(_ id: String)
}

/// A sink that records what it receives; for tests and the stub server.
public final class RecordingSink: DocumentSink {
    public struct Snapshot: Sendable {
        public var documents: [DocumentContent]
    }

    private let state = OSAllocatedUnfairLock(initialState: [DocumentContent]())
    private let onChange: (@Sendable (DocumentContent) -> Void)?

    /// `onChange` runs after every change, with the changed document.
    public init(onChange: (@Sendable (DocumentContent) -> Void)? = nil) {
        self.onChange = onChange
    }

    public var documents: [DocumentContent] { state.withLock { $0 } }

    public func document(_ id: String) -> DocumentContent? {
        state.withLock { docs in docs.first { $0.id == id } }
    }

    public func open(_ document: DocumentContent) {
        state.withLock { $0.append(document) }
        onChange?(document)
    }

    public func append(_ entries: [ChangesetEntry], toDocument id: String) {
        let changed = state.withLock { docs -> DocumentContent? in
            guard let index = docs.firstIndex(where: { $0.id == id }) else { return nil }
            docs[index].entries += entries
            return docs[index]
        }
        if let changed { onChange?(changed) }
    }

    public func complete(_ id: String) {
        let changed = state.withLock { docs -> DocumentContent? in
            guard let index = docs.firstIndex(where: { $0.id == id }) else { return nil }
            docs[index].isComplete = true
            return docs[index]
        }
        if let changed { onChange?(changed) }
    }
}
