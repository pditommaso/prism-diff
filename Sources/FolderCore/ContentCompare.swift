// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// The optional "compare file contents" check: decides whether a pair that
/// metadata calls changed really differs, by reading bytes.
///
/// Byte comparison, not hashing: the cost is dominated by opening and
/// reading files, and memcmp with early exit beats any hash (DECISIONS D4).
/// Large files are compared in parallel ranges.
enum ContentCompare {
    private static let chunk = 1 << 20
    private static let parallelThreshold: UInt64 = 32 << 20

    /// True when the two files have the same bytes.
    static func sameFile(_ a: String, _ b: String, cancelled: @Sendable () -> Bool = { false }) -> Bool {
        let fa = open(a, O_RDONLY | O_CLOEXEC)
        if fa < 0 { return false }
        defer { close(fa) }
        let fb = open(b, O_RDONLY | O_CLOEXEC)
        if fb < 0 { return false }
        defer { close(fb) }
        var sa = stat(), sb = stat()
        guard fstat(fa, &sa) == 0, fstat(fb, &sb) == 0, sa.st_size == sb.st_size else { return false }
        let size = UInt64(max(0, sa.st_size))
        if size == 0 { return true }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        if size < parallelThreshold { return sameRange(fa, fb, 0, size, cancelled) }
        let parts = 8
        let step = (size + UInt64(parts) - 1) / UInt64(parts)
        let verdicts = Verdicts()
        DispatchQueue.concurrentPerform(iterations: parts) { index in
            let start = UInt64(index) * step
            guard start < size, !verdicts.anyDifferent else { return }
            if !sameRange(fa, fb, start, min(size, start + step), cancelled) { verdicts.markDifferent() }
        }
        return !verdicts.anyDifferent
    }

    /// A cancelled comparison answers "different" (the verdict is dropped).
    private static func sameRange(_ fa: Int32, _ fb: Int32, _ start: UInt64, _ end: UInt64,
                                  _ cancelled: () -> Bool) -> Bool {
        let ba = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        let bb = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }
        var offset = start
        while offset < end {
            if cancelled() { return false }
            let want = Int(min(UInt64(chunk), end - offset))
            let ra = pread(fa, ba, want, off_t(offset))
            let rb = pread(fb, bb, want, off_t(offset))
            if ra != want || rb != want { return false }
            if memcmp(ba, bb, want) != 0 { return false }
            offset += UInt64(want)
        }
        return true
    }

    /// True when two directories hold the same items with the same bytes:
    /// same names and kinds throughout, symlinks and aliases by name,
    /// unreadable items by name, files by content. Dates are ignored.
    static func sameDirectory(_ a: String, _ b: String, reader: any DirectoryReader, includeHidden: Bool,
                              cancelled: @Sendable () -> Bool = { false }) -> Bool {
        var pending: [(String, String)] = [(a, b)]
        while let (left, right) = pending.popLast() {
            if cancelled() { return false }
            guard let listA = listing(left, reader, includeHidden),
                  let listB = listing(right, reader, includeHidden),
                  listA.count == listB.count else { return false }
            for (name, itemA) in listA {
                guard let itemB = listB[name], itemA.kind == itemB.kind, itemA.readable == itemB.readable else {
                    return false
                }
                guard itemA.readable else { continue }
                switch itemA.kind {
                case .directory: pending.append((left + "/" + name, right + "/" + name))
                case .symlink, .alias: continue
                case .file, .other:
                    if itemA.size != itemB.size { return false }
                    if itemA.mtimeNs == itemB.mtimeNs { continue }
                    if !sameFile(left + "/" + name, right + "/" + name, cancelled: cancelled) { return false }
                }
            }
        }
        return true
    }

    private struct Item {
        var kind: EntryKind
        var size: UInt64
        var mtimeNs: Int64
        var readable: Bool
    }

    private static func listing(_ path: String, _ reader: any DirectoryReader,
                                _ includeHidden: Bool) -> [String: Item]? {
        var items: [String: Item] = [:]
        let status = reader.read(path) { raw in
            if raw.isSkipped(includeHidden: includeHidden) { return }
            items[raw.nameString] = Item(kind: raw.kind, size: raw.size, mtimeNs: raw.mtimeNs, readable: raw.readable)
        }
        return status == 0 ? items : nil
    }

    private final class Verdicts: @unchecked Sendable {
        private var different = false
        private let lock = NSLock()
        var anyDifferent: Bool { lock.withLock { different } }
        func markDifferent() { lock.withLock { different = true } }
    }
}
