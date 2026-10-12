// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin

/// Lists one displayed level of one side into entries.
enum LevelLister {
    struct Listing {
        var entries: [FolderEntry] = []
        /// 0, or the errno of the listing (ENOENT when the folder is
        /// missing on this side).
        var error: Int32 = 0
    }

    /// Lists `relativePath` below `rootPath`. Directory entries get their
    /// deep key from `tree` (the side's retained tree) when it is given and
    /// holds that directory; otherwise their shallow key.
    static func list(rootPath: String, relativePath: String, reader: any DirectoryReader,
                     includeHidden: Bool, tree: DirectoryNode?) -> Listing {
        let directory = relativePath.isEmpty ? rootPath : rootPath + "/" + relativePath
        let parentHash = Digest.path(relativePath)
        let parentIsRoot = relativePath.isEmpty
        let node = tree?.descendant(at: relativePath)
        var listing = Listing()
        var symlinks: [Int] = []
        listing.error = reader.read(directory) { item in
            if item.isSkipped(includeHidden: includeHidden) { return }
            let hash = Digest.child(of: parentHash, parentIsRoot: parentIsRoot, name: item.name)
            let name = item.nameString
            let entry: FolderEntry
            switch item.kind {
            case .directory:
                entry = directoryEntry(name: name, hash: hash, mtimeNs: item.mtimeNs, readable: item.readable,
                                       node: node?.child(named: name))
            case .symlink:
                symlinks.append(listing.entries.count)
                entry = FolderEntry(name: name, kind: .symlink, size: 0, modificationTimeNs: item.mtimeNs,
                                    isReadable: item.readable, key: Digest.linkKey(path: hash), isDeep: true)
            case .alias:
                entry = FolderEntry(name: name, kind: .alias, size: item.size, modificationTimeNs: item.mtimeNs,
                                    isReadable: item.readable, key: Digest.linkKey(path: hash), isDeep: true)
            case .file, .other:
                let key = item.readable
                    ? Digest.fileKey(path: hash, size: item.size, mtimeNs: item.mtimeNs)
                    : Digest.unreadableKey(path: hash)
                entry = FolderEntry(name: name, kind: item.kind, size: item.size, modificationTimeNs: item.mtimeNs,
                                    isReadable: item.readable, key: key, isDeep: true)
            }
            listing.entries.append(entry)
        }
        // A symlink shows the size of what it points to.
        for index in symlinks {
            var info = stat()
            if stat(directory + "/" + listing.entries[index].name, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                listing.entries[index].size = UInt64(max(0, info.st_size))
            }
        }
        return listing
    }

    /// A directory entry: deep when the tree knows it, shallow otherwise.
    /// An unreadable directory compares by name and is final at once.
    static func directoryEntry(name: String, hash: UInt64, mtimeNs: Int64, readable: Bool,
                               node: DirectoryNode?) -> FolderEntry {
        if !readable {
            return FolderEntry(name: name, kind: .directory, size: 0, modificationTimeNs: mtimeNs, isReadable: false,
                               key: Digest.unreadableKey(path: hash), isDeep: true)
        }
        if let node, node.readable {
            return FolderEntry(name: name, kind: .directory, size: node.totals.size, modificationTimeNs: mtimeNs,
                               isReadable: true, key: node.deepKey, isDeep: true,
                               descendantCount: node.totals.count)
        }
        return FolderEntry(name: name, kind: .directory, size: 0, modificationTimeNs: mtimeNs, isReadable: true,
                           key: Digest.directoryShallow(path: hash), isDeep: false)
    }

    /// Replaces the keys of the directory entries with the tree's current
    /// deep keys (after a change somewhere below this level).
    static func refreshDirectories(_ entries: inout [FolderEntry], relativePath: String, tree: DirectoryNode?) {
        guard let tree, let node = tree.descendant(at: relativePath) else { return }
        let parentHash = Digest.path(relativePath)
        for index in entries.indices where entries[index].kind == .directory {
            let old = entries[index]
            let hash = Digest.child(of: parentHash, parentIsRoot: relativePath.isEmpty, name: old.name)
            let child = node.child(named: old.name)
            entries[index] = directoryEntry(name: old.name, hash: hash, mtimeNs: child?.mtimeNs ?? old.modificationTimeNs,
                                            readable: old.isReadable, node: child)
        }
    }
}
