// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin

/// Maps byte strings to dense `Int32` ids, using open addressing with linear
/// probing.
///
/// Dense ids make token equality a single integer compare, and let the unique
/// anchor pass count occurrences in a flat array instead of a dictionary.
///
/// Keys are borrowed pointers into the caller's buffers and are never copied:
/// an interner must not outlive the scope those pointers are valid in (for
/// `TextDiff`, the duration of one `diff` call). Storage is column-oriented
/// raw memory so that a probe touches no reference-counted state.
final class Interner {
    /// Slot table: 0 means empty, otherwise the entry id + 1.
    private var table: UnsafeMutablePointer<Int32>
    private var mask: Int
    private(set) var count = 0

    // Entry columns, indexed by id.
    private var hashes: UnsafeMutablePointer<UInt64>
    private var keys: UnsafeMutablePointer<UnsafePointer<UInt8>>
    private var lengths: UnsafeMutablePointer<Int32>
    /// Keys of 8 bytes or less, packed little-endian (0 for longer keys).
    private var packed: UnsafeMutablePointer<UInt64>
    private var entryCapacity: Int

    init(expected: Int) {
        var slots = 16
        while slots < expected * 2 { slots <<= 1 }
        table = .allocate(capacity: slots)
        table.initialize(repeating: 0, count: slots)
        mask = slots - 1
        entryCapacity = max(expected, 8)
        hashes = .allocate(capacity: entryCapacity)
        keys = .allocate(capacity: entryCapacity)
        lengths = .allocate(capacity: entryCapacity)
        packed = .allocate(capacity: entryCapacity)
    }

    deinit {
        table.deallocate()
        hashes.deallocate()
        keys.deallocate()
        lengths.deallocate()
        packed.deallocate()
    }

    /// Empties the table for reuse, keeping its memory (avoids an allocation
    /// per line pair during refinement).
    func reset() {
        table.update(repeating: 0, count: mask + 1)
        count = 0
    }

    /// Multiplicative hash reading 8 bytes at a time.
    @inline(__always)
    static func hash(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(n)
        let raw = UnsafeRawPointer(p)
        var i = 0
        while i + 8 <= n {
            let word = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            h = (h ^ word) &* 0xBF58_476D_1CE4_E5B9
            h ^= h >> 31
            i += 8
        }
        var tail: UInt64 = 0
        var shift: UInt64 = 0
        while i < n {
            tail |= UInt64(p[i]) << shift
            shift += 8
            i += 1
        }
        h = (h ^ tail) &* 0x94D0_49BB_1331_11EB
        h ^= h >> 29
        return h
    }

    /// The id of the `n` bytes at `p`, assigning the next id if they are new.
    @inline(__always)
    func intern(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int32 {
        if n <= 8 { return internShort(p, n) }
        let h = Interner.hash(p, n)
        var slot = Int(truncatingIfNeeded: h) & mask
        while true {
            let entry = table[slot]
            if entry == 0 { return insert(at: slot, hash: h, key: p, length: n, packed: 0) }
            let id = Int(entry) - 1
            if hashes[id] == h && Int(lengths[id]) == n && memcmp(keys[id], p, n) == 0 {
                return Int32(id)
            }
            slot = (slot + 1) & mask
        }
    }

    /// Most word tokens are short. Packing them into one integer makes a
    /// lookup a hash plus one 64-bit compare, with no memcmp call.
    @inline(__always)
    private func internShort(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int32 {
        var word: UInt64 = 0
        var i = 0
        while i < n {
            word |= UInt64(p[i]) << UInt64(i << 3)
            i += 1
        }
        var h = (word ^ (UInt64(n) << 59)) &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 31
        var slot = Int(truncatingIfNeeded: h) & mask
        while true {
            let entry = table[slot]
            if entry == 0 { return insert(at: slot, hash: h, key: p, length: n, packed: word) }
            let id = Int(entry) - 1
            if packed[id] == word && Int(lengths[id]) == n { return Int32(id) }
            slot = (slot + 1) & mask
        }
    }

    private func insert(at slot: Int, hash: UInt64, key: UnsafePointer<UInt8>,
                        length: Int, packed word: UInt64) -> Int32 {
        let id = count
        if id == entryCapacity { growEntries() }
        hashes[id] = hash
        keys[id] = key
        lengths[id] = Int32(length)
        packed[id] = word
        table[slot] = Int32(id + 1)
        count += 1
        if count * 2 > mask + 1 { rehash() }
        return Int32(id)
    }

    private static func grow<T>(_ column: inout UnsafeMutablePointer<T>, from old: Int, to new: Int) {
        let fresh = UnsafeMutablePointer<T>.allocate(capacity: new)
        fresh.moveInitialize(from: column, count: old)
        column.deallocate()
        column = fresh
    }

    private func growEntries() {
        let newCapacity = entryCapacity * 2
        Interner.grow(&hashes, from: entryCapacity, to: newCapacity)
        Interner.grow(&keys, from: entryCapacity, to: newCapacity)
        Interner.grow(&lengths, from: entryCapacity, to: newCapacity)
        Interner.grow(&packed, from: entryCapacity, to: newCapacity)
        entryCapacity = newCapacity
    }

    private func rehash() {
        let slots = (mask + 1) * 2
        table.deallocate()
        table = .allocate(capacity: slots)
        table.initialize(repeating: 0, count: slots)
        mask = slots - 1
        for id in 0 ..< count {
            var slot = Int(truncatingIfNeeded: hashes[id]) & mask
            while table[slot] != 0 { slot = (slot + 1) & mask }
            table[slot] = Int32(id + 1)
        }
    }
}
