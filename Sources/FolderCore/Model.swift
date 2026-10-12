// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Folder scanning and comparison: the engine behind the folder view.
///
/// `FolderSession` compares two folder trees. Each displayed level (the
/// roots, or a subfolder reached by drilling down) is a `FolderLevel`: two
/// aligned lists of entries with a status per row.
public enum FolderCore {
    public static let moduleName = "FolderCore"
}

/// Scan and comparison settings. Changing any of them needs a new session.
public struct FolderOptions: Sendable, Hashable {
    /// Include dot-files and items with the hidden flag. `.DS_Store` is
    /// excluded whatever this says.
    public var includeHidden: Bool
    /// Read file contents to confirm that a same-size pair whose dates
    /// differ really differs. Off by default: metadata alone decides.
    public var compareContents: Bool
    public var method: ScanMethod
    /// Worker threads of the deep pass.
    public var workers: Int
    /// Delay before FSEvents delivers a change, in seconds (0.05-0.1).
    public var eventLatency: Double

    /// 8 worker threads, or fewer on machines with fewer cores (never below
    /// 2): parallel speed-up saturates around 6-8 threads (DECISIONS D4).
    public static var defaultWorkers: Int { max(2, min(8, ProcessInfo.processInfo.activeProcessorCount)) }

    public init(includeHidden: Bool = false, compareContents: Bool = false, method: ScanMethod = .automatic,
                workers: Int = FolderOptions.defaultWorkers, eventLatency: Double = 0.05) {
        self.includeHidden = includeHidden
        self.compareContents = compareContents
        self.method = method
        self.workers = workers
        self.eventLatency = eventLatency
    }
}

/// One item on one side of a level.
public struct FolderEntry: Sendable, Hashable {
    public let name: String
    public let kind: EntryKind
    /// Files: bytes (for a symlink, the size of its target). Directories:
    /// the total size of all descendant files once `isDeep`, else 0.
    public var size: UInt64
    public let modificationTimeNs: Int64
    public let isReadable: Bool
    /// The comparison key. Equal keys on both sides mean "unchanged".
    public var key: UInt64
    /// Directories: true once the subtree digest is known (second pass).
    /// Always true for other kinds.
    public var isDeep: Bool
    /// Directories: the number of items below, once `isDeep`.
    public var descendantCount: Int

    public init(name: String, kind: EntryKind, size: UInt64, modificationTimeNs: Int64, isReadable: Bool,
                key: UInt64, isDeep: Bool, descendantCount: Int = 0) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modificationTimeNs = modificationTimeNs
        self.isReadable = isReadable
        self.key = key
        self.isDeep = isDeep
        self.descendantCount = descendantCount
    }

    public var isDirectory: Bool { kind == .directory }

    public var modificationDate: Date {
        Date(timeIntervalSince1970: Double(modificationTimeNs) / 1_000_000_000)
    }
}

/// The status of a row.
public enum RowStatus: String, Sendable, Hashable, CaseIterable {
    /// Present on both sides with equal keys.
    case unchanged
    /// Present on both sides (same name), different.
    case changed
    /// Only on the left.
    case leftOnly = "left-only"
    /// Only on the right.
    case rightOnly = "right-only"

    public var isUnmatched: Bool { self == .leftOnly || self == .rightOnly }
}

/// For a changed row, the side with the later modification time.
public enum NewerSide: String, Sendable, Hashable {
    case none, left, right
}

/// One aligned row: an entry on either or both sides.
public struct FolderRow: Sendable, Hashable {
    public var left: FolderEntry?
    public var right: FolderEntry?
    public var status: RowStatus
    public var newer: NewerSide
    /// True while a directory on this row waits for the second pass (or a
    /// pair waits for the content check): the UI shows a spinner.
    public var isPending: Bool

    public init(left: FolderEntry?, right: FolderEntry?, status: RowStatus, newer: NewerSide = .none,
                isPending: Bool = false) {
        precondition(left != nil || right != nil, "a row needs at least one entry")
        self.left = left
        self.right = right
        self.status = status
        self.newer = newer
        self.isPending = isPending
    }

    /// The row's name: the left name, or the right one for right-only rows.
    public var name: String { left?.name ?? right?.name ?? "" }

    public func entry(_ side: Side) -> FolderEntry? { side == .left ? left : right }

    /// True when both sides are directories: opening the row drills down.
    public var isFolderPair: Bool {
        (left?.isDirectory ?? true) && (right?.isDirectory ?? true)
    }
}

public enum Side: Int, Sendable, Hashable, CaseIterable {
    case left = 0, right = 1

    public var opposite: Side { self == .left ? .right : .left }
}

/// Which statuses are shown. The raw values match the classic bitmask
/// (unmatched 0x2, changed 0x4, unchanged 0x8); empty means "show all".
public struct FolderFilter: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let unmatched = FolderFilter(rawValue: 0x2)
    public static let changed = FolderFilter(rawValue: 0x4)
    public static let unchanged = FolderFilter(rawValue: 0x8)
    public static let all: FolderFilter = [.unmatched, .changed, .unchanged]

    public func shows(_ status: RowStatus) -> Bool {
        if isEmpty { return true }
        switch status {
        case .unchanged: return contains(.unchanged)
        case .changed: return contains(.changed)
        case .leftOnly, .rightOnly: return contains(.unmatched)
        }
    }
}

/// Row counts per filter group, always over the unfiltered rows.
public struct FolderCounts: Sendable, Hashable {
    public var changed = 0
    public var unchanged = 0
    public var unmatched = 0

    public init(changed: Int = 0, unchanged: Int = 0, unmatched: Int = 0) {
        self.changed = changed
        self.unchanged = unchanged
        self.unmatched = unmatched
    }

    public init(_ rows: [FolderRow]) {
        for row in rows {
            switch row.status {
            case .changed: changed += 1
            case .unchanged: unchanged += 1
            case .leftOnly, .rightOnly: unmatched += 1
            }
        }
    }

    public var total: Int { changed + unchanged + unmatched }
}

/// The column a level is sorted by.
public enum FolderSortKey: String, Sendable, Hashable {
    case name, date, size
}

public struct FolderSort: Sendable, Hashable {
    public var key: FolderSortKey
    /// Date and size sorts use this side's values (the table whose header
    /// was clicked); a row missing on that side uses the other side.
    public var side: Side
    public var ascending: Bool

    public init(key: FolderSortKey = .name, side: Side = .left, ascending: Bool = true) {
        self.key = key
        self.side = side
        self.ascending = ascending
    }

    public static let byName = FolderSort()
}
