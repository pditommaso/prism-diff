// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Finder order: localized standard compare (case-insensitive, numbers by
/// value), then plain byte order so that names equal under that compare
/// (`Foo` and `foo`) still get one fixed order.
public enum FinderOrder {
    public static func precedes(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
    }

    public static func sorted(_ entries: [FolderEntry]) -> [FolderEntry] {
        entries.sorted { precedes($0.name, $1.name) }
    }
}

/// A run of the edit script between two key sequences.
struct EditHunk: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case equal, delete, insert }
    var kind: Kind
    var a: Range<Int>
    var b: Range<Int>
}

/// Shortest edit script between the key sequences of two sorted listings.
///
/// Keys are unique within a side (they hash the relative path), and both
/// sides are sorted by the same total order of names, so the keys present on
/// both sides appear in the same relative order in each: the longest common
/// subsequence is exactly the set of shared keys. That makes the classic
/// O(ND) search unnecessary; one hash lookup per item finds the same script
/// in linear time. A key whose partner would break the order (only possible
/// after a hash collision) is treated as unmatched, which still yields a
/// valid script.
enum EditScript {
    static func hunks(_ a: [UInt64], _ b: [UInt64]) -> [EditHunk] {
        var indexInB: [UInt64: Int] = [:]
        indexInB.reserveCapacity(b.count)
        for (j, key) in b.enumerated() where indexInB[key] == nil { indexInB[key] = j }
        var hunks: [EditHunk] = []
        func push(_ kind: EditHunk.Kind, _ i: Int, _ j: Int, _ da: Int, _ db: Int) {
            if let last = hunks.last, last.kind == kind, last.a.upperBound == i, last.b.upperBound == j {
                hunks[hunks.count - 1].a = last.a.lowerBound..<(i + da)
                hunks[hunks.count - 1].b = last.b.lowerBound..<(j + db)
            } else {
                hunks.append(EditHunk(kind: kind, a: i..<(i + da), b: j..<(j + db)))
            }
        }
        var j = 0
        for (i, key) in a.enumerated() {
            if let match = indexInB[key], match >= j {
                while j < match {
                    push(.insert, i, j, 0, 1)
                    j += 1
                }
                push(.equal, i, j, 1, 1)
                j += 1
            } else {
                push(.delete, i, j, 1, 0)
            }
        }
        while j < b.count {
            push(.insert, a.count, j, 0, 1)
            j += 1
        }
        return hunks
    }
}

/// Turns two listings of the same level into aligned rows.
public enum FolderRows {
    /// Rows for two listings: equal keys pair as unchanged; the remaining
    /// items pair as changed when their names are exactly equal (case
    /// sensitive, whatever their kinds); the rest are left- or right-only.
    /// Rows are in Finder order of their names.
    public static func build(left: [FolderEntry], right: [FolderEntry]) -> [FolderRow] {
        let sortedLeft = FinderOrder.sorted(left), sortedRight = FinderOrder.sorted(right)
        let hunks = EditScript.hunks(sortedLeft.map(\.key), sortedRight.map(\.key))
        var rows: [FolderRow] = []
        rows.reserveCapacity(max(left.count, right.count))
        var unmatchedLeft: [FolderEntry] = []
        var unmatchedRight: [FolderEntry] = []
        for hunk in hunks {
            switch hunk.kind {
            case .equal:
                for (i, j) in zip(hunk.a, hunk.b) {
                    let l = sortedLeft[i], r = sortedRight[j]
                    rows.append(FolderRow(left: l, right: r, status: .unchanged,
                                          isPending: !l.isDeep || !r.isDeep))
                }
            case .delete: unmatchedLeft.append(contentsOf: hunk.a.map { sortedLeft[$0] })
            case .insert: unmatchedRight.append(contentsOf: hunk.b.map { sortedRight[$0] })
            }
        }
        var rightByName: [String: FolderEntry] = [:]
        for entry in unmatchedRight { rightByName[entry.name] = entry }
        // Swift String equality is canonical (NFC == NFD); pairing must be
        // exact, so compare names by their UTF-8 bytes.
        var paired = Set<String>()
        for l in unmatchedLeft {
            if let r = rightByName[l.name], Array(r.name.utf8) == Array(l.name.utf8) {
                paired.insert(r.name)
                let newer: NewerSide = l.modificationTimeNs > r.modificationTimeNs
                    ? .left : (r.modificationTimeNs > l.modificationTimeNs ? .right : .none)
                rows.append(FolderRow(left: l, right: r, status: .changed, newer: newer,
                                      isPending: !l.isDeep || !r.isDeep))
            } else {
                rows.append(FolderRow(left: l, right: nil, status: .leftOnly, isPending: !l.isDeep))
            }
        }
        for r in unmatchedRight where !paired.contains(r.name) {
            rows.append(FolderRow(left: nil, right: r, status: .rightOnly, isPending: !r.isDeep))
        }
        return sorted(rows, by: .byName)
    }

    /// Rows in the given order. Name order puts equal names left before
    /// right; date and size orders fall back to name order on ties.
    public static func sorted(_ rows: [FolderRow], by sort: FolderSort) -> [FolderRow] {
        func nameOrder(_ a: FolderRow, _ b: FolderRow) -> Bool {
            if a.name != b.name { return FinderOrder.precedes(a.name, b.name) }
            // Same name on two rows: a file and a folder that did not pair,
            // or left-only before right-only.
            if a.left != nil, b.left == nil { return true }
            return false
        }
        func value(_ row: FolderRow) -> (date: Int64, size: UInt64) {
            let entry = row.entry(sort.side) ?? row.entry(sort.side.opposite)
            return (entry?.modificationTimeNs ?? 0, entry?.size ?? 0)
        }
        let ascending: (FolderRow, FolderRow) -> Bool
        switch sort.key {
        case .name:
            ascending = nameOrder
        case .date:
            ascending = { a, b in
                let va = value(a).date, vb = value(b).date
                return va != vb ? va < vb : nameOrder(a, b)
            }
        case .size:
            ascending = { a, b in
                let va = value(a).size, vb = value(b).size
                return va != vb ? va < vb : nameOrder(a, b)
            }
        }
        return sort.ascending ? rows.sorted(by: ascending) : rows.sorted { ascending($1, $0) }
    }

    /// The rows a filter shows (counts stay computed over all rows).
    public static func filtered(_ rows: [FolderRow], _ filter: FolderFilter) -> [FolderRow] {
        filter.isEmpty || filter == .all ? rows : rows.filter { filter.shows($0.status) }
    }
}
