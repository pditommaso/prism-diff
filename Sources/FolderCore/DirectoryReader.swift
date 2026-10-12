// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin

/// The kind of a directory item, as the scanner sees it.
public enum EntryKind: UInt8, Sendable, Hashable {
    case file
    case directory
    case symlink
    /// A Finder alias file. Compared by name only, like a symlink.
    case alias
    /// Sockets, FIFOs, devices: compared like files.
    case other
}

/// One item of a directory listing, valid only inside the reader callback:
/// `name` points into the reader's buffer.
struct RawItem {
    var name: UnsafeBufferPointer<UInt8>
    var kind: EntryKind
    var size: UInt64
    var mtimeNs: Int64
    /// BSD flags (`st_flags`), for UF_HIDDEN.
    var flags: UInt32
    var readable: Bool
    /// The file's inode number (0 when unknown): tells a folder renamed
    /// into place from the folder that had its name before.
    var fileID: UInt64 = 0

    var nameString: String { String(decoding: name, as: UTF8.self) }

    /// `.DS_Store` is always skipped; hidden items (a leading dot or the
    /// hidden flag) unless hidden files are scanned.
    @inline(__always)
    func isSkipped(includeHidden: Bool) -> Bool {
        if name.count == 9, name.elementsEqual(".DS_Store".utf8) { return true }
        if includeHidden { return false }
        return name.first == UInt8(ascii: ".") || flags & UInt32(UF_HIDDEN) != 0
    }
}

/// Which system interface lists directories.
public enum ScanMethod: String, Sendable, Hashable, CaseIterable {
    /// `getattrlistbulk` on APFS and HFS+, `fts` elsewhere.
    case automatic
    /// Always `getattrlistbulk(2)`.
    case bulk
    /// Always `fts(3)`, the fallback for volumes without bulk attributes.
    case fts
}

/// Lists one directory level.
protocol DirectoryReader: Sendable {
    /// Calls `body` for every item directly inside `path`, skipped ones
    /// included. Returns 0, or the errno that stopped the listing.
    @discardableResult
    func read(_ path: String, _ body: (RawItem) -> Void) -> Int32
}

enum DirectoryReaders {
    /// The reader for a comparison root: `method`, or for `.automatic` the
    /// bulk reader on file systems that implement bulk attributes natively.
    static func reader(for root: String, method: ScanMethod) -> any DirectoryReader {
        switch method {
        case .bulk: return BulkReader()
        case .fts: return FTSReader()
        case .automatic: return supportsBulk(root) ? AdaptiveReader() : FTSReader()
        }
    }

    /// True on APFS and HFS+, whose drivers answer `getattrlistbulk`
    /// natively. On SMB, NFS, FAT and exFAT the kernel only emulates it, so
    /// `fts` is used there.
    static func supportsBulk(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return true }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return type == "apfs" || type == "hfs"
    }

    /// The file-system type name of `path` (`apfs`, `smbfs`, ...).
    static func fileSystemType(_ path: String) -> String {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

@inline(__always)
func nanoseconds(_ time: timespec) -> Int64 {
    Int64(time.tv_sec) &* 1_000_000_000 &+ Int64(time.tv_nsec)
}

// MARK: - getattrlistbulk

/// Lists a directory with `getattrlistbulk(2)`: one system call returns the
/// name, type, modification time, flags, access and size of many items.
struct BulkReader: DirectoryReader {
    private static let bufferSize = 128 * 1024
    private static let finderAliasFlag: UInt16 = 0x8000

    func read(_ path: String, _ body: (RawItem) -> Void) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { return errno }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FNDRINFO) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_USERACCESS)
            | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            var record = buffer
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let item = Self.decode(record) { body(item) }
                record += length
            }
        }
    }

    /// Decodes one packed record. Attributes appear in bitmap order, and
    /// only those flagged in the returned set are present.
    private static func decode(_ record: UnsafeMutableRawPointer) -> RawItem? {
        var cursor = UnsafeRawPointer(record) + 4
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        var failed = false
        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            failed = cursor.loadUnaligned(as: UInt32.self) != 0
            cursor += 4
        }
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let reference = cursor.loadUnaligned(as: attrreference_t.self)
        let namePointer = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
        let nameLength = max(0, Int(reference.attr_length) - 1)
        cursor += MemoryLayout<attrreference_t>.size
        guard nameLength > 0 else { return nil }
        var item = RawItem(name: UnsafeBufferPointer(start: namePointer, count: nameLength),
                           kind: .file, size: 0, mtimeNs: 0, flags: 0, readable: !failed)
        var objectType: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            objectType = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            item.mtimeNs = nanoseconds(cursor.loadUnaligned(as: timespec.self))
            cursor += MemoryLayout<timespec>.size
        }
        var finderFlags: UInt16 = 0
        if common & attrgroup_t(ATTR_CMN_FNDRINFO) != 0 {
            // FileInfo.finderFlags, big-endian, at offset 8 of the 32 bytes.
            finderFlags = UInt16(bigEndian: (cursor + 8).loadUnaligned(as: UInt16.self))
            cursor += 32
        }
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            item.flags = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if common & attrgroup_t(ATTR_CMN_USERACCESS) != 0 {
            if cursor.loadUnaligned(as: UInt32.self) & UInt32(R_OK) == 0 { item.readable = false }
            cursor += 4
        }
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            item.fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            item.size = UInt64(max(0, cursor.loadUnaligned(as: off_t.self)))
        }
        switch objectType {
        case UInt32(VDIR.rawValue): item.kind = .directory
        case UInt32(VLNK.rawValue): item.kind = .symlink
        case UInt32(VREG.rawValue):
            item.kind = finderFlags & finderAliasFlag != 0 ? .alias : .file
        default: item.kind = .other
        }
        if item.kind == .directory { item.size = 0 }
        return item
    }
}

/// Bulk attributes, falling back to `fts` for a directory whose file system
/// refuses `getattrlistbulk`, or that bulk attributes cannot list for lack
/// of permission (a folder that can be read but not searched still gives
/// its names through `fts`).
struct AdaptiveReader: DirectoryReader {
    func read(_ path: String, _ body: (RawItem) -> Void) -> Int32 {
        var delivered = false
        let status = BulkReader().read(path) { item in
            delivered = true
            body(item)
        }
        if !delivered && (status == ENOTSUP || status == EINVAL || status == EACCES || status == EPERM) {
            return FTSReader().read(path, body)
        }
        return status
    }
}

// MARK: - fts

/// Lists a directory with `fts(3)`, one level deep. Used on volumes where
/// bulk attributes are only emulated (SMB, NFS, FAT, exFAT). Finder aliases
/// are not detected here: they compare like ordinary files.
struct FTSReader: DirectoryReader {
    func read(_ path: String, _ body: (RawItem) -> Void) -> Int32 {
        guard let root = strdup(path) else { return ENOMEM }
        defer { free(root) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return errno }
        defer { fts_close(stream) }
        let uid = geteuid()
        var status: Int32 = 0
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            if level == 0 {
                if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                    status = entry.pointee.fts_errno
                }
                if info == FTS_DP { break }
                continue
            }
            if info == FTS_D { fts_set(stream, entry, FTS_SKIP) }
            if info == FTS_DP || info == FTS_DC { continue }
            // The name is the tail of fts_path (fts_name is a flexible array
            // member, awkward to address from Swift).
            let nameLength = Int(entry.pointee.fts_namelen)
            guard let fullPath = entry.pointee.fts_path else { continue }
            let nameStart = UnsafeRawPointer(fullPath + (Int(entry.pointee.fts_pathlen) - nameLength))
            let name = UnsafeBufferPointer(start: nameStart.assumingMemoryBound(to: UInt8.self), count: nameLength)
            var item = RawItem(name: name, kind: .file, size: 0, mtimeNs: 0, flags: 0, readable: true)
            if let stat = entry.pointee.fts_statp, info != FTS_NS {
                let st = stat.pointee
                item.mtimeNs = nanoseconds(st.st_mtimespec)
                item.flags = st.st_flags
                item.size = UInt64(max(0, st.st_size))
                item.readable = Self.readable(st, uid: uid)
                item.fileID = UInt64(st.st_ino)
            } else {
                item.readable = false
            }
            switch info {
            case FTS_D, FTS_DNR: item.kind = .directory; item.size = 0
            case FTS_SL, FTS_SLNONE: item.kind = .symlink
            case FTS_F: item.kind = .file
            case FTS_NS: item.kind = .file
            default: item.kind = .other
            }
            body(item)
        }
        return status
    }

    /// Read permission from the mode bits, without another system call per
    /// item (an `access` round trip is expensive on network volumes).
    static func readable(_ st: stat, uid: uid_t) -> Bool {
        if uid == 0 { return true }
        let mode = st.st_mode
        if st.st_uid == uid { return mode & S_IRUSR != 0 }
        if mode & S_IROTH != 0 { return true }
        if mode & S_IRGRP != 0 { return isMember(of: st.st_gid) }
        return false
    }

    private static func isMember(of group: gid_t) -> Bool {
        if getegid() == group { return true }
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        return count > 0 && groups.prefix(Int(count)).contains(group)
    }
}
