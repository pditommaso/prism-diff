// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// One directory of a retained side tree.
///
/// Only directories are kept: files are listed again when a level is shown,
/// which costs one system call per directory, so the tree stays small (one
/// node per directory) while still answering, for any directory, the digest,
/// size and item count of its whole subtree.
///
/// Thread safety: during a scan a node is written by exactly one worker and
/// handed over through the scanner's lock; afterwards it is only touched on
/// the owning session's queue.
final class DirectoryNode: @unchecked Sendable {
    let name: String
    /// Path relative to the comparison root ("" for the root).
    let relativePath: String
    /// Hash of `relativePath`.
    let pathHash: UInt64
    var mtimeNs: Int64
    var readable: Bool
    /// Inode number of the folder (0 when unknown).
    var fileID: UInt64 = 0
    /// Terms of the direct children (files, links, and each subdirectory's
    /// own identity), without the subdirectories' contents.
    var own = SubtreeTotals()
    /// Every descendant: `own` plus the `totals` of every child directory.
    var totals = SubtreeTotals()
    var children: [DirectoryNode] = []
    weak var parent: DirectoryNode?

    init(name: String, relativePath: String, pathHash: UInt64, mtimeNs: Int64, readable: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.pathHash = pathHash
        self.mtimeNs = mtimeNs
        self.readable = readable
    }

    static func root() -> DirectoryNode {
        DirectoryNode(name: "", relativePath: "", pathHash: Digest.pathSeed, mtimeNs: 0, readable: true)
    }

    var isRoot: Bool { relativePath.isEmpty }

    func child(named name: String) -> DirectoryNode? {
        children.first { $0.name == name }
    }

    /// The node at `relativePath` below this one ("" is this node).
    func descendant(at relativePath: String) -> DirectoryNode? {
        var node = self
        if relativePath.isEmpty { return node }
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = node.child(named: String(component)) else { return nil }
            node = next
        }
        return node
    }

    /// The comparison key of this directory as an entry of its parent.
    var deepKey: UInt64 {
        readable ? Digest.directoryDeep(path: pathHash, subtree: totals.digest) : Digest.unreadableKey(path: pathHash)
    }

    /// This directory's own term in its ancestors' digests.
    var term: UInt64 {
        Digest.term(readable ? Digest.directoryOwn(path: pathHash) : Digest.unreadableKey(path: pathHash))
    }

    /// Recomputes `totals` bottom-up for this subtree.
    func sumTotals() {
        // Iterative post-order: deep trees must not exhaust the stack.
        var order: [DirectoryNode] = []
        var stack: [DirectoryNode] = [self]
        while let node = stack.popLast() {
            order.append(node)
            stack.append(contentsOf: node.children)
        }
        for node in order.reversed() {
            var totals = node.own
            for child in node.children { totals.add(child.totals) }
            node.totals = totals
        }
    }

    var nodeCount: Int {
        var count = 0
        var stack: [DirectoryNode] = [self]
        while let node = stack.popLast() {
            count += 1
            stack.append(contentsOf: node.children)
        }
        return count
    }
}

/// What one directory level contributes: the terms of its direct children
/// and the subdirectories found.
struct LevelScan {
    var own = SubtreeTotals()
    var subdirectories: [DirectoryNode] = []
    var error: Int32 = 0
}

enum LevelScanner {
    /// Lists `path` (the directory of `node`) and returns its own terms and
    /// new, unscanned child nodes.
    static func scan(_ node: DirectoryNode, path: String, reader: any DirectoryReader,
                     includeHidden: Bool) -> LevelScan {
        var result = LevelScan()
        let parentHash = node.pathHash, parentIsRoot = node.isRoot
        result.error = reader.read(path) { item in
            if item.isSkipped(includeHidden: includeHidden) { return }
            let hash = Digest.child(of: parentHash, parentIsRoot: parentIsRoot, name: item.name)
            switch item.kind {
            case .directory:
                let name = item.nameString
                let child = DirectoryNode(
                    name: name, relativePath: parentIsRoot ? name : node.relativePath + "/" + name,
                    pathHash: hash, mtimeNs: item.mtimeNs, readable: item.readable)
                child.fileID = item.fileID
                child.parent = node
                result.subdirectories.append(child)
                result.own.digest &+= child.term
                result.own.directories += 1
            case .symlink, .alias:
                result.own.digest &+= Digest.term(Digest.linkKey(path: hash))
                result.own.links += 1
            case .file, .other:
                let key = item.readable
                    ? Digest.fileKey(path: hash, size: item.size, mtimeNs: item.mtimeNs)
                    : Digest.unreadableKey(path: hash)
                result.own.digest &+= Digest.term(key)
                result.own.size &+= item.size
                result.own.files += 1
            }
        }
        return result
    }
}

/// The deep pass: walks whole subtrees with a fixed pool of worker threads
/// pulling directories from a shared stack.
///
/// A fixed pool, not a task per directory: the work is blocking system
/// calls, which must not occupy Swift's cooperative threads, and one task
/// per directory costs far more memory (DECISIONS D4).
final class TreeScanner: @unchecked Sendable {
    struct Job {
        let node: DirectoryNode
        let path: String
        let side: Int
    }

    struct Root {
        let node: DirectoryNode
        let path: String
        let reader: any DirectoryReader
    }

    private let condition = NSCondition()
    private var stack: [Job] = []
    private var pending = 0
    private var errors = 0
    private let roots: [Root]
    private let includeHidden: Bool
    private let cancelled: @Sendable () -> Bool

    private init(roots: [Root], includeHidden: Bool, cancelled: @escaping @Sendable () -> Bool) {
        self.roots = roots
        self.includeHidden = includeHidden
        self.cancelled = cancelled
    }

    /// Scans every root completely (each root node's children are replaced)
    /// and sums the totals. Blocks until done. Returns the number of
    /// directories that could not be listed.
    @discardableResult
    static func scan(_ roots: [Root], includeHidden: Bool, workers: Int = FolderOptions.defaultWorkers,
                     cancelled: @escaping @Sendable () -> Bool = { false }) -> Int {
        let scanner = TreeScanner(roots: roots, includeHidden: includeHidden, cancelled: cancelled)
        return scanner.run(workers: max(1, workers))
    }

    private func run(workers: Int) -> Int {
        for (side, root) in roots.enumerated() {
            root.node.children = []
            root.node.own = SubtreeTotals()
            if root.node.readable { stack.append(Job(node: root.node, path: root.path, side: side)) }
        }
        pending = stack.count
        if pending > 0 {
            let done = DispatchGroup()
            for _ in 0..<workers {
                done.enter()
                let thread = Thread { [self] in
                    work()
                    done.leave()
                }
                thread.stackSize = 1 << 20
                thread.qualityOfService = .userInitiated
                thread.start()
            }
            done.wait()
        }
        for root in roots { root.node.sumTotals() }
        return errors
    }

    private func work() {
        while true {
            condition.lock()
            while stack.isEmpty && pending > 0 { condition.wait() }
            if pending == 0 {
                condition.unlock()
                return
            }
            let job = stack.removeLast()
            condition.unlock()

            var scan = LevelScan()
            if !cancelled() {
                scan = LevelScanner.scan(job.node, path: job.path, reader: roots[job.side].reader,
                                         includeHidden: includeHidden)
                job.node.own = scan.own
                job.node.children = scan.subdirectories
            }
            let next = scan.subdirectories.filter(\.readable).map {
                Job(node: $0, path: job.path + "/" + $0.name, side: job.side)
            }

            condition.lock()
            if scan.error != 0 { errors += 1 }
            stack.append(contentsOf: next)
            pending += next.count - 1
            if pending == 0 || !next.isEmpty { condition.broadcast() }
            condition.unlock()
        }
    }
}
