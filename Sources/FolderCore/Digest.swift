// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

/// Hashing for the folder comparison.
///
/// Every entry gets a 64-bit comparison key derived from its path relative to
/// the comparison root plus, for regular files, its size and modification
/// time. Two entries on opposite sides are "the same" when their keys match.
///
/// A directory's deep key folds in the digest of its whole subtree. That
/// digest is a wrapping *sum* of one mixed term per descendant, so it does
/// not depend on enumeration order: parallel workers merge partial digests
/// with `+`, and a change below a directory updates every ancestor by the
/// difference between the old and new digest of the directory that changed.
enum Digest {
    static let pathSeed: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3
    private static let directoryTag: UInt64 = 0xd1d1_d1d1_0000_0001
    private static let linkTag: UInt64 = 0x5151_5151_0000_0002
    private static let countTerm: UInt64 = 0x9e37_79b9_7f4a_7c15

    // MARK: Path hashing (FNV-1a over UTF-8 bytes of the relative path)

    @inline(__always)
    static func byte(_ hash: UInt64, _ value: UInt8) -> UInt64 {
        (hash ^ UInt64(value)) &* prime
    }

    @inline(__always)
    static func bytes(_ hash: UInt64, _ buffer: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var h = hash
        for value in buffer { h = (h ^ UInt64(value)) &* prime }
        return h
    }

    static func string(_ hash: UInt64, _ text: String) -> UInt64 {
        var copy = text
        return copy.withUTF8 { bytes(hash, $0) }
    }

    /// Hash of `<parent>/<name>`, given the hash of the parent's relative
    /// path. The root's own relative path is empty, so its children hash as
    /// just `<name>`.
    @inline(__always)
    static func child(of parent: UInt64, parentIsRoot: Bool, name: UnsafeBufferPointer<UInt8>) -> UInt64 {
        bytes(parentIsRoot ? parent : byte(parent, UInt8(ascii: "/")), name)
    }

    static func child(of parent: UInt64, parentIsRoot: Bool, name: String) -> UInt64 {
        var copy = name
        return copy.withUTF8 { child(of: parent, parentIsRoot: parentIsRoot, name: $0) }
    }

    /// Hash of a relative path such as `src/util` (empty for the root).
    static func path(_ relativePath: String) -> UInt64 {
        relativePath.isEmpty ? pathSeed : string(pathSeed, relativePath)
    }

    // MARK: Mixing

    @inline(__always)
    static func scramble(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    @inline(__always)
    static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 { scramble(a ^ scramble(b)) }

    // MARK: Entry keys

    /// A regular file: path, size and modification time.
    @inline(__always)
    static func fileKey(path: UInt64, size: UInt64, mtimeNs: Int64) -> UInt64 {
        mix(mix(path, size), UInt64(bitPattern: mtimeNs))
    }

    /// Symbolic links, aliases and unreadable items compare by path only.
    @inline(__always)
    static func linkKey(path: UInt64) -> UInt64 { path ^ linkTag }

    @inline(__always)
    static func unreadableKey(path: UInt64) -> UInt64 { path }

    /// A directory's own identity, without its contents.
    @inline(__always)
    static func directoryOwn(path: UInt64) -> UInt64 { path ^ directoryTag }

    /// The shallow key of a directory: its path only. Two directories with
    /// the same name match in the first pass and are refined by the second.
    @inline(__always)
    static func directoryShallow(path: UInt64) -> UInt64 { mix(directoryOwn(path: path), 0) }

    /// The deep key of a directory: its path and the digest of its subtree.
    @inline(__always)
    static func directoryDeep(path: UInt64, subtree: UInt64) -> UInt64 {
        mix(directoryOwn(path: path) &+ 1, subtree)
    }

    /// One descendant's term in its ancestors' subtree digest.
    @inline(__always)
    static func term(_ key: UInt64) -> UInt64 { scramble(key) &+ countTerm }
}

/// Totals over a subtree. Every field is a sum, so subtrees combine with
/// `add` and changes apply as differences.
public struct SubtreeTotals: Sendable, Equatable {
    /// Order-independent digest of every descendant's key.
    public var digest: UInt64 = 0
    /// Sum of the sizes of the descendant files.
    public var size: UInt64 = 0
    public var files: Int = 0
    public var directories: Int = 0
    public var links: Int = 0

    public init() {}

    public var count: Int { files + directories + links }

    @inline(__always)
    mutating func add(_ other: SubtreeTotals) {
        digest &+= other.digest
        size &+= other.size
        files += other.files
        directories += other.directories
        links += other.links
    }

    @inline(__always)
    mutating func subtract(_ other: SubtreeTotals) {
        digest &-= other.digest
        size &-= other.size
        files -= other.files
        directories -= other.directories
        links -= other.links
    }
}
