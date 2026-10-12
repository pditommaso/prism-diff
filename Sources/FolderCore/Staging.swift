// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// The direction of a staged copy.
public enum CopyDirection: String, Sendable, Hashable, CaseIterable {
    /// From A (left) to B (right).
    case toRight = "to-right"
    /// From B (right) to A (left).
    case toLeft = "to-left"

    public var source: Side { self == .toRight ? .left : .right }
    public var destination: Side { self == .toRight ? .right : .left }
}

extension FolderRow {
    /// Identifies the row within its level across refreshes: which sides
    /// hold an entry, plus the name.
    public var identity: String {
        (left == nil ? "-" : "L") + (right == nil ? "-" : "R") + name
    }

    /// The copy directions this row allows: only-left rows copy right,
    /// only-right rows copy left, changed rows either way, unchanged rows
    /// not at all. Allowed directions are listed right first.
    public var allowedDirections: [CopyDirection] {
        switch status {
        case .unchanged: return []
        case .leftOnly: return [.toRight]
        case .rightOnly: return [.toLeft]
        case .changed: return [.toRight, .toLeft]
        }
    }
}

/// One staged choice: copy an item of a level to the other side.
public struct StagedCopy: Sendable, Hashable {
    /// The row identity (`FolderRow.identity`) in its level.
    public let rowIdentity: String
    /// The item's name.
    public let name: String
    /// Path below both roots, level path included (`src/util/helper.swift`).
    public let relativePath: String
    public let direction: CopyDirection
    /// True when the destination already exists and will be replaced.
    public let replaces: Bool
    public let isDirectory: Bool
    /// The source size in bytes (for a folder, its descendants' total).
    public let size: UInt64
    /// The row's status when it was staged (for colours).
    public let status: RowStatus

    public init(row: FolderRow, levelPath: String, direction: CopyDirection) {
        let source = row.entry(direction.source)
        rowIdentity = row.identity
        name = row.name
        relativePath = levelPath.isEmpty ? row.name : levelPath + "/" + row.name
        self.direction = direction
        replaces = row.entry(direction.destination) != nil
        isDirectory = source?.isDirectory ?? false
        size = source?.size ?? 0
        status = row.status
    }
}

/// The staged copy directions of one level, keyed by row identity.
///
/// A value type: the app snapshots it for undo and redo.
public struct FolderStaging: Sendable, Hashable {
    public let levelPath: String
    public private(set) var choices: [String: StagedCopy] = [:]

    public init(levelPath: String) { self.levelPath = levelPath }

    public var count: Int { choices.count }
    public var isEmpty: Bool { choices.isEmpty }

    public func direction(of row: FolderRow) -> CopyDirection? { choices[row.identity]?.direction }

    /// Stages `direction` on every row that allows it; other rows keep
    /// their choice. Returns true when anything changed.
    @discardableResult
    public mutating func stage(_ rows: [FolderRow], _ direction: CopyDirection) -> Bool {
        var changed = false
        for row in rows where row.allowedDirections.contains(direction) {
            let copy = StagedCopy(row: row, levelPath: levelPath, direction: direction)
            if choices[row.identity] != copy {
                choices[row.identity] = copy
                changed = true
            }
        }
        return changed
    }

    /// Sets or clears one row's choice. A direction the row does not allow
    /// is ignored.
    public mutating func set(_ row: FolderRow, _ direction: CopyDirection?) {
        if let direction {
            guard row.allowedDirections.contains(direction) else { return }
            choices[row.identity] = StagedCopy(row: row, levelPath: levelPath, direction: direction)
        } else {
            choices[row.identity] = nil
        }
    }

    /// The gutter button: none, then each allowed direction, then none.
    public mutating func cycle(_ row: FolderRow) {
        let allowed = row.allowedDirections
        guard !allowed.isEmpty else { return }
        let next: CopyDirection?
        if let current = direction(of: row), let index = allowed.firstIndex(of: current) {
            next = index + 1 < allowed.count ? allowed[index + 1] : nil
        } else {
            next = allowed[0]
        }
        set(row, next)
    }

    /// Clears the choices of `rows`. Returns true when anything changed.
    @discardableResult
    public mutating func reset(_ rows: [FolderRow]) -> Bool {
        var changed = false
        for row in rows where choices.removeValue(forKey: row.identity) != nil { changed = true }
        return changed
    }

    public mutating func resetAll() { choices.removeAll() }

    /// Brings the choices in line with fresh rows: a choice whose row is
    /// gone or no longer allows its direction is dropped (for example a row
    /// that became unchanged after the copy); the others take the row's
    /// current sizes and whether the destination exists.
    @discardableResult
    public mutating func reconcile(with rows: [FolderRow]) -> Bool {
        guard !choices.isEmpty else { return false }
        var byIdentity: [String: FolderRow] = [:]
        for row in rows { byIdentity[row.identity] = row }
        var updated: [String: StagedCopy] = [:]
        for (identity, copy) in choices {
            guard let row = byIdentity[identity], row.allowedDirections.contains(copy.direction) else { continue }
            updated[identity] = StagedCopy(row: row, levelPath: levelPath, direction: copy.direction)
        }
        let changed = updated != choices
        choices = updated
        return changed
    }

    /// The staged copies in the order they run: by name, Finder order.
    public var ordered: [StagedCopy] {
        choices.values.sorted { FinderOrder.precedes($0.name, $1.name) }
    }

    /// Bytes to copy, from the row sizes.
    public var totalBytes: UInt64 { choices.values.reduce(0) { $0 &+ $1.size } }
}
