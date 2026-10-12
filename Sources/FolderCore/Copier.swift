// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation

// MARK: - Trash

/// Moves replaced items out of the way. The app uses the Finder Trash;
/// tests and acceptance runs use a plain directory, so they never fill the
/// user's Trash.
public protocol TrashMover: Sendable {
    /// Moves the item at `path` (never following a final symbolic link) and
    /// returns where it went, when known.
    func trash(_ path: String) throws -> String?
}

/// The Finder Trash, through `FileManager.trashItem`.
public struct SystemTrash: TrashMover {
    public init() {}

    public func trash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: &resulting)
        return (resulting as URL?)?.path(percentEncoded: false)
    }
}

/// A trash that is a plain directory: items are renamed into it, with a
/// number added when the name is taken. The directory must be on the same
/// volume as the items.
public struct DirectoryTrash: TrashMover {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    public func trash(_ path: String) throws -> String? {
        if mkdir(directory, 0o755) != 0 && errno != EEXIST { throw CopyError.posix(errno, "mkdir") }
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var attempt = 1
        while true {
            let candidate = attempt == 1 ? name : (ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)")
            let target = directory + "/" + candidate
            var info = stat()
            if lstat(target, &info) != 0 {
                guard rename(path, target) == 0 else { throw CopyError.posix(errno, "rename") }
                return target
            }
            attempt += 1
        }
    }
}

// MARK: - Lock

/// Paths taking part in a copy, across every window of the process. A copy
/// that would touch a path (or a folder above or below it) already in use
/// is refused.
public final class CopyLock: @unchecked Sendable {
    public static let shared = CopyLock()

    private let lock = NSLock()
    private var held: [Int: [String]] = [:]
    private var nextID = 0

    public init() {}

    /// A held set of paths; `release()` (or deinit) gives them back.
    public final class Lease: @unchecked Sendable {
        private let onRelease: () -> Void
        private let released = Flag()

        init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }

        public func release() {
            guard !released.value else { return }
            released.value = true
            onRelease()
        }

        deinit { release() }
    }

    /// Takes every path, or none: returns the lease, or the first path that
    /// is already part of another copy.
    public func acquire(_ paths: [String]) -> Result<Lease, CopyLockConflict> {
        let keys = paths.map(Self.key)
        lock.lock()
        defer { lock.unlock() }
        for (path, key) in zip(paths, keys) {
            for other in held.values.joined() where Self.overlaps(key, other) {
                return .failure(CopyLockConflict(path: path))
            }
        }
        let id = nextID
        nextID += 1
        held[id] = keys
        return .success(Lease { [weak self] in self?.release(id) })
    }

    public var isEmpty: Bool { lock.withLock { held.isEmpty } }

    /// True when `path` (or a folder above or below it) is part of a copy.
    public func isHeld(_ path: String) -> Bool {
        let key = Self.key(path)
        return lock.withLock { held.values.joined().contains { Self.overlaps(key, $0) } }
    }

    /// The path as the file system matches names: one Unicode form always
    /// (APFS and HFS+ ignore it), and folded case on a case-insensitive
    /// volume, so `README` and `Readme`, or two spellings of `café`, are
    /// the same path there.
    static func key(_ path: String) -> String {
        let normalized = path.decomposedStringWithCanonicalMapping
        return caseSensitive(path) ? normalized : normalized.lowercased()
    }

    /// Asks the volume of the nearest existing folder of `path`.
    static func caseSensitive(_ path: String) -> Bool {
        var probe = path
        while !probe.isEmpty {
            let answer = pathconf(probe, _PC_CASE_SENSITIVE)
            if answer >= 0 { return answer != 0 }
            if probe == "/" { break }
            probe = (probe as NSString).deletingLastPathComponent
        }
        return false
    }

    private func release(_ id: Int) {
        lock.withLock { _ = held.removeValue(forKey: id) }
    }

    static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}

public struct CopyLockConflict: Error, Sendable, Equatable {
    public let path: String
}

// MARK: - Errors and progress

enum CopyError: Error {
    case posix(Int32, String)
    case cancelled
    case outsideRoot(String)
    case unsupported(String)
    /// The destination exists under another spelling (case or Unicode
    /// form), or appeared after the item was staged as new.
    case nameConflict(String)
}

/// A failed item, offered to the caller with the recovery choices.
public struct CopyFailure: Error, Sendable, Equatable {
    public let name: String
    public let relativePath: String
    public let direction: CopyDirection
    public let sourcePath: String
    public let destinationPath: String
    /// The POSIX error, 0 when there is none (for example a path that
    /// leaves the compared folder).
    public let code: Int32
    /// What failed, in a few words ("open", "rename", "move to Trash").
    public let operation: String
    /// The path the failing operation was about.
    public let failingPath: String

    /// One sentence for an alert's title.
    public var title: String {
        let from = ((sourcePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let to = ((destinationPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return "Prism couldn\u{2019}t copy \u{201C}\(name)\u{201D} from \u{201C}\(from)\u{201D} to \u{201C}\(to)\u{201D}."
    }

    /// The reason, for an alert's message.
    public var reason: String {
        switch code {
        case 0: return "The item is reached through a symbolic link that leads outside the compared folders, so Prism left it alone."
        case EEXIST:
            return "\u{201C}\(failingPath)\u{201D} is already there, under a name that differs only in case or accents, or since the copy was staged. Prism left it alone instead of replacing it."
        case EACCES, EPERM, EROFS:
            return "Permission denied while trying to \(operation) \u{201C}\(failingPath)\u{201D}."
        default:
            return "Could not \(operation) \u{201C}\(failingPath)\u{201D}: \(String(cString: strerror(code)))."
        }
    }
}

/// What to do about a failed item.
public enum CopyRecovery: Sendable, Equatable {
    /// Try the item again.
    case retry
    /// Leave the item and go on with the next one.
    case skip
    /// Stop the whole copy.
    case stop
}

public enum CopyPhase: String, Sendable {
    case preparing, copying, replacing
}

public struct CopyProgress: Sendable, Equatable {
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    /// 0-based index of the item being copied.
    public var itemIndex: Int
    public var itemCount: Int
    public var name: String
    public var phase: CopyPhase

    public init(completedBytes: UInt64, totalBytes: UInt64, itemIndex: Int, itemCount: Int, name: String,
                phase: CopyPhase) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.name = name
        self.phase = phase
    }

    public var fraction: Double {
        totalBytes == 0 ? (itemCount == 0 ? 1 : Double(itemIndex) / Double(itemCount))
            : min(1, Double(completedBytes) / Double(totalBytes))
    }
}

/// How a copy ended.
public struct CopyOutcome: Sendable, Equatable {
    /// Relative paths copied, in order.
    public var copied: [String] = []
    /// Relative paths skipped after an error.
    public var skipped: [String] = []
    /// Where each replaced destination went (relative path -> trash path).
    public var trashed: [String: String] = [:]
    /// Relative paths never attempted (after a cancel or a stop).
    public var notAttempted: [String] = []
    public var cancelled = false
    public var stopped = false
    public var copiedBytes: UInt64 = 0

    public var finished: Bool { !cancelled && !stopped }
}

// MARK: - Copier

/// Copies staged items from one root to the other.
///
/// - Items run one after the other, in Finder order of their names.
/// - Each item is first copied into a hidden temporary name next to its
///   destination. Only once the copy is complete is an existing
///   destination moved to the trash and the copy renamed into place, so a
///   cancelled or failed item leaves nothing behind and the old
///   destination untouched.
/// - Symbolic links are copied as links and never followed, and every path
///   is checked to stay inside its root: a folder on the way that is a
///   symbolic link stops the item.
/// - Modification times are kept to the nanosecond, so a copied item
///   compares as unchanged afterwards.
/// - Progress is weighted by bytes; `cancel()` may be called from any
///   thread and stops within one chunk.
public final class FolderCopier: @unchecked Sendable {
    public let leftRoot: String
    public let rightRoot: String
    public let items: [StagedCopy]
    private let trash: any TrashMover
    private let allowClone: Bool
    private let chunkSize: Int
    private let cancelled = Flag()

    /// - Parameters:
    ///   - allowClone: clone files (APFS) when the volume allows it: instant
    ///     and space-saving. Tests turn it off to exercise the byte copy.
    ///   - chunkSize: bytes per read in the byte copy.
    public init(leftRoot: String, rightRoot: String, items: [StagedCopy], trash: any TrashMover,
                allowClone: Bool = true, chunkSize: Int = 1 << 20) {
        self.leftRoot = FolderSession.canonical(leftRoot)
        self.rightRoot = FolderSession.canonical(rightRoot)
        self.items = items.sorted { FinderOrder.precedes($0.name, $1.name) }
        self.trash = trash
        self.allowClone = allowClone
        self.chunkSize = max(4096, chunkSize)
    }

    public func cancel() { cancelled.value = true }
    public var isCancelled: Bool { cancelled.value }

    public func root(_ side: Side) -> String { side == .left ? leftRoot : rightRoot }

    public func sourcePath(_ item: StagedCopy) -> String { join(root(item.direction.source), item.relativePath) }
    public func destinationPath(_ item: StagedCopy) -> String { join(root(item.direction.destination), item.relativePath) }

    /// Every source and destination path, for `CopyLock`.
    public var lockPaths: [String] { items.flatMap { [sourcePath($0), destinationPath($0)] } }

    private func join(_ root: String, _ relative: String) -> String {
        root == "/" ? "/" + relative : root + "/" + relative
    }

    /// Runs the copy on the calling thread. `progress` is called often (at
    /// least once per chunk); `onError` decides what happens after a
    /// failure and may block (for example while an alert is up).
    public func run(progress: (CopyProgress) -> Void = { _ in },
                    onError: (CopyFailure) -> CopyRecovery = { _ in .skip }) -> CopyOutcome {
        var outcome = CopyOutcome()
        var state = CopyProgress(completedBytes: 0, totalBytes: 0, itemIndex: 0, itemCount: items.count,
                                 name: items.first?.name ?? "", phase: .preparing)
        progress(state)
        var sizes: [UInt64] = []
        for item in items {
            sizes.append(Self.treeSize(sourcePath(item), cancelled: cancelled))
            if cancelled.value { break }
        }
        state.totalBytes = sizes.reduce(0, &+)
        var index = 0
        while index < items.count {
            let item = items[index]
            if cancelled.value {
                outcome.cancelled = true
                outcome.notAttempted = items[index...].map(\.relativePath)
                break
            }
            state.itemIndex = index
            state.name = item.name
            state.phase = .copying
            let startBytes = state.completedBytes
            progress(state)
            do {
                let trashed = try copy(item) { bytes, phase in
                    state.completedBytes = startBytes &+ bytes
                    state.phase = phase
                    progress(state)
                }
                outcome.copied.append(item.relativePath)
                if let trashed { outcome.trashed[item.relativePath] = trashed }
                state.completedBytes = startBytes &+ (index < sizes.count ? sizes[index] : 0)
                outcome.copiedBytes = state.completedBytes
                index += 1
            } catch CopyError.cancelled {
                outcome.cancelled = true
                outcome.notAttempted = items[index...].map(\.relativePath)
                break
            } catch {
                state.completedBytes = startBytes
                let failure = describe(error, item)
                switch onError(failure) {
                case .retry:
                    continue
                case .skip:
                    outcome.skipped.append(item.relativePath)
                    state.completedBytes = startBytes &+ (index < sizes.count ? sizes[index] : 0)
                    index += 1
                case .stop:
                    outcome.stopped = true
                    outcome.notAttempted = items[(index + 1)...].map(\.relativePath)
                    outcome.skipped.append(item.relativePath)
                    index = items.count
                }
            }
        }
        state.phase = .copying
        progress(state)
        return outcome
    }

    private var failingPath = ""

    private func describe(_ error: Error, _ item: StagedCopy) -> CopyFailure {
        var code: Int32 = EIO, operation = "copy"
        switch error {
        case CopyError.posix(let c, let op): code = c; operation = op
        case CopyError.outsideRoot: code = 0; operation = "reach"
        case CopyError.unsupported: code = ENOTSUP; operation = "copy"
        case CopyError.nameConflict: code = EEXIST; operation = "replace"
        case let error as NSError where error.domain == NSPOSIXErrorDomain:
            code = Int32(error.code); operation = "move to the Trash"
        case let error as NSError:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                code = Int32(underlying.code)
            } else if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
                code = EACCES
            }
            operation = "move to the Trash"
        }
        return CopyFailure(name: item.name, relativePath: item.relativePath, direction: item.direction,
                           sourcePath: sourcePath(item), destinationPath: destinationPath(item), code: code,
                           operation: operation, failingPath: failingPath.isEmpty ? destinationPath(item) : failingPath)
    }

    // MARK: one item

    /// An open directory descriptor, closed on deinit.
    final class Directory {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { close(fd) }

        /// The directory's current path, as the kernel knows it.
        var path: String {
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return "" }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// File flags a user may set again on a copy (uchg, uappnd, nodump,
    /// opaque, hidden).
    static let settableFlags = UInt32(UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_OPAQUE | UF_HIDDEN)

    /// Copies one item; returns where a replaced destination went.
    ///
    /// Every step after the walk works relative to the open source and
    /// destination parent folders, never through paths, so a folder
    /// swapped for a symbolic link while the copy runs cannot redirect it.
    private func copy(_ item: StagedCopy, progress: (UInt64, CopyPhase) -> Void) throws -> String? {
        failingPath = ""
        let components = item.relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw CopyError.outsideRoot(item.relativePath)
        }
        let source = sourcePath(item), destination = destinationPath(item)
        // Copying a folder into itself (one root inside the other).
        if CopyLock.overlaps(source, destination) { throw CopyError.outsideRoot(destination) }
        let name = components.last!
        let sourceParent = try walk(root(item.direction.source), components.dropLast(), create: false).directory
        let (parent, created) = try walk(root(item.direction.destination), components.dropLast(), create: true)
        do {
            return try install(item, name: name, from: sourceParent, into: parent, destination: destination,
                               progress: progress)
        } catch {
            // Folders made for this item go again (deepest first; only if
            // still empty).
            for path in created.reversed() { _ = rmdir(path) }
            throw error
        }
    }

    private func install(_ item: StagedCopy, name: String, from sourceParent: Directory, into parent: Directory,
                         destination: String, progress: (UInt64, CopyPhase) -> Void) throws -> String? {
        var sourceInfo = stat()
        guard fstatat(sourceParent.fd, name, &sourceInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw fail(errno, "read", sourcePath(item))
        }
        // What is at the destination now, under which name on disk.
        var existing = stat()
        let exists = fstatat(parent.fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            let onDisk = Self.entryNames(parent.fd).first { Self.sameEntry(parent.fd, $0, existing) }
            if let onDisk, Array(onDisk.utf8) != Array(name.utf8) {
                failingPath = (destination as NSString).deletingLastPathComponent + "/" + onDisk
                throw CopyError.nameConflict(onDisk)
            }
            if !item.replaces {
                failingPath = destination
                throw CopyError.nameConflict(name)
            }
        }

        let temporary = Self.temporaryName(for: name)
        var copied: UInt64 = 0
        var topFlags: UInt32 = 0
        do {
            topFlags = try copyEntry(sourceParent.fd, name, parent.fd, temporary, top: true, copied: &copied,
                                     progress: { progress($0, .copying) })
            if cancelled.value { throw CopyError.cancelled }
        } catch {
            Self.removeTree(at: parent.fd, temporary)
            throw error
        }

        guard exists else {
            // Nothing to replace: never clobber an item that appeared since.
            guard renameatx_np(parent.fd, temporary, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                Self.removeTree(at: parent.fd, temporary)
                if code == EEXIST {
                    failingPath = destination
                    throw CopyError.nameConflict(name)
                }
                throw fail(code, "move into place", destination)
            }
            Self.setFlags(parent.fd, name, topFlags)
            return nil
        }

        // Replace: park the old item, under its own name, in a hidden
        // folder next to it; install the new one; trash the old one; and
        // put everything back if any step fails.
        progress(copied, .replacing)
        let backupName = temporary + "-old"
        guard mkdirat(parent.fd, backupName, 0o700) == 0 else {
            let code = errno
            Self.removeTree(at: parent.fd, temporary)
            throw fail(code, "move to the Trash", destination)
        }
        func discard() {
            Self.removeTree(at: parent.fd, temporary)
            _ = unlinkat(parent.fd, backupName, AT_REMOVEDIR)
        }
        // The item must still be the one checked above.
        var now = stat()
        guard fstatat(parent.fd, name, &now, AT_SYMLINK_NOFOLLOW) == 0,
              now.st_dev == existing.st_dev, now.st_ino == existing.st_ino else {
            discard()
            failingPath = destination
            throw CopyError.nameConflict(name)
        }
        let backupFD = openat(parent.fd, backupName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard backupFD >= 0 else {
            let code = errno
            discard()
            throw fail(code, "move to the Trash", destination)
        }
        let backup = Directory(backupFD)
        guard renameat(parent.fd, name, backup.fd, name) == 0 else {
            let code = errno
            discard()
            throw fail(code, "move to the Trash", destination)
        }
        func restore() {
            _ = renameatx_np(backup.fd, name, parent.fd, name, UInt32(RENAME_EXCL))
            discard()
        }
        guard renameatx_np(parent.fd, temporary, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            restore()
            throw fail(code, "move into place", destination)
        }
        var parked = stat()
        let trashed: String?
        do {
            guard fstatat(backup.fd, name, &parked, AT_SYMLINK_NOFOLLOW) == 0,
                  parked.st_dev == existing.st_dev, parked.st_ino == existing.st_ino else {
                throw CopyError.posix(ENOENT, "move to the Trash")
            }
            failingPath = destination
            trashed = try trash.trash(backup.path + "/" + name) ?? ""
        } catch {
            // Undo: the new item back to its temporary name, the old one
            // back in place.
            _ = renameatx_np(parent.fd, name, parent.fd, temporary, UInt32(RENAME_EXCL))
            restore()
            if case CopyError.posix(let code, _) = error { throw CopyError.posix(code, "move to the Trash") }
            throw error
        }
        _ = unlinkat(parent.fd, backupName, AT_REMOVEDIR)
        // Locks go on last, once nothing needs to move the item any more.
        Self.setFlags(parent.fd, name, topFlags)
        return trashed
    }

    /// The names in a directory.
    static func entryNames(_ fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// True when `name` in the directory is the item `info` describes.
    static func sameEntry(_ fd: Int32, _ name: String, _ info: stat) -> Bool {
        var other = stat()
        return fstatat(fd, name, &other, AT_SYMLINK_NOFOLLOW) == 0 && other.st_dev == info.st_dev && other.st_ino == info.st_ino
    }

    static func temporaryName(for name: String) -> String {
        let tag = String(UUID().uuidString.prefix(8))
        var short = name
        while short.utf8.count > 200 { short.removeLast() }
        return "\(temporaryPrefix)\(tag)-\(short)"
    }

    static let temporaryPrefix = ".prism-copy-"

    /// Opens `components` below `root`, one real directory at a time, with
    /// O_NOFOLLOW: anything on the way that is not a directory (a symbolic
    /// link in particular) stops the item. Missing folders are created
    /// when `create` is set; their paths are returned, outermost first.
    private func walk(_ root: String, _ components: ArraySlice<String>,
                      create: Bool) throws -> (directory: Directory, created: [String]) {
        let rootFD = open(root, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else { throw fail(errno, "open the folder", root) }
        var current = Directory(rootFD)
        var path = root
        var created: [String] = []
        do {
            for component in components {
                path = path == "/" ? "/" + component : path + "/" + component
                var fd = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if fd < 0 && errno == ENOENT && create {
                    guard mkdirat(current.fd, component, 0o755) == 0 else { throw fail(errno, "create the folder", path) }
                    created.append(path)
                    fd = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                guard fd >= 0 else {
                    let code = errno
                    var info = stat()
                    if fstatat(current.fd, component, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFLNK {
                        failingPath = path
                        throw CopyError.outsideRoot(path)
                    }
                    throw fail(code == ELOOP ? ENOTDIR : code, "open the folder", path)
                }
                current = Directory(fd)
            }
        } catch {
            for made in created.reversed() { _ = rmdir(made) }
            throw error
        }
        return (current, created)
    }

    private func fail(_ code: Int32, _ operation: String, _ path: String) -> CopyError {
        failingPath = path
        return .posix(code, operation)
    }

    /// Copies `sourceName` in `sourceDir` to the new `targetName` in
    /// `targetDir`, recursively, without following symbolic links. File
    /// flags are applied to everything below; the top item's flags are
    /// returned instead, for the caller to apply once it is in place.
    private func copyEntry(_ sourceDir: Int32, _ sourceName: String, _ targetDir: Int32, _ targetName: String,
                           top: Bool, copied: inout UInt64, progress: (UInt64) -> Void) throws -> UInt32 {
        if cancelled.value { throw CopyError.cancelled }
        var info = stat()
        let sourceLabel = sourceName
        guard fstatat(sourceDir, sourceName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail(errno, "read", sourceLabel) }
        let flags = info.st_flags & Self.settableFlags
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlinkat(sourceDir, sourceName, &buffer, buffer.count - 1)
            guard length >= 0 else { throw fail(errno, "read the link", sourceLabel) }
            buffer[length] = 0
            guard symlinkat(buffer, targetDir, targetName) == 0 else { throw fail(errno, "create the link", targetName) }
            var times = [info.st_atimespec, info.st_mtimespec]
            _ = utimensat(targetDir, targetName, &times, AT_SYMLINK_NOFOLLOW)
            return 0
        case S_IFDIR:
            let input = openat(sourceDir, sourceName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard input >= 0 else { throw fail(errno, "read the folder", sourceLabel) }
            let sourceFolder = Directory(input)
            guard mkdirat(targetDir, targetName, 0o700) == 0 else { throw fail(errno, "create the folder", targetName) }
            let output = openat(targetDir, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard output >= 0 else { throw fail(errno, "open the folder", targetName) }
            let targetFolder = Directory(output)
            for child in Self.entryNames(sourceFolder.fd).sorted(by: FinderOrder.precedes) {
                _ = try copyEntry(sourceFolder.fd, child, targetFolder.fd, child, top: false, copied: &copied,
                                  progress: progress)
            }
            try copyMetadata(sourceFolder.fd, targetFolder.fd, info, label: targetName)
            if !top && flags != 0 { _ = fchflags(targetFolder.fd, flags) }
        case S_IFREG:
            let input = openat(sourceDir, sourceName, O_RDONLY | O_NOFOLLOW)
            guard input >= 0 else { throw fail(errno, "open", sourceLabel) }
            defer { close(input) }
            var output: Int32 = -1
            if allowClone && fclonefileat(input, targetDir, targetName, UInt32(CLONE_NOFOLLOW)) == 0 {
                output = openat(targetDir, targetName, O_RDONLY | O_NOFOLLOW)
                guard output >= 0 else { throw fail(errno, "open", targetName) }
                defer { close(output) }
                // A clone carries the flags; clear them until the end.
                _ = fchflags(output, 0)
                copied &+= UInt64(max(info.st_size, 0))
                progress(copied)
                if !top && flags != 0 { _ = fchflags(output, flags) }
                return top ? flags : 0
            }
            output = openat(targetDir, targetName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw fail(errno, "create", targetName) }
            defer { close(output) }
            try copyBytes(input, output, label: (sourceLabel, targetName), copied: &copied, progress: progress)
            try copyMetadata(input, output, info, label: targetName)
            if !top && flags != 0 { _ = fchflags(output, flags) }
        default:
            failingPath = sourceLabel
            throw CopyError.unsupported(sourceLabel)
        }
        return top ? flags : 0
    }

    private func copyBytes(_ input: Int32, _ output: Int32, label: (String, String), copied: inout UInt64,
                           progress: (UInt64) -> Void) throws {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            if cancelled.value { throw CopyError.cancelled }
            let count = read(input, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw fail(errno, "read", label.0)
            }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = write(output, buffer + offset, count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw fail(errno, "write", label.1)
                }
                offset += written
            }
            copied &+= UInt64(count)
            progress(copied)
        }
    }

    /// Extended attributes and ACLs (fcopyfile on the open descriptors),
    /// then the mode and the times to the nanosecond.
    private func copyMetadata(_ input: Int32, _ output: Int32, _ info: stat, label: String) throws {
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0 else {
            throw fail(errno, "copy the attributes of", label)
        }
        guard fchmod(output, info.st_mode & 0o7777) == 0 else { throw fail(errno, "set the permissions of", label) }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard futimens(output, &times) == 0 else { throw fail(errno, "set the dates of", label) }
    }

    /// Sets the user flags of an item that is in place.
    static func setFlags(_ dir: Int32, _ name: String, _ flags: UInt32) {
        guard flags != 0 else { return }
        var fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        if fd < 0 { fd = openat(dir, name, O_EVTONLY | O_NOFOLLOW) }
        guard fd >= 0 else { return }
        _ = fchflags(fd, flags)
        close(fd)
    }

    /// Deletes a temporary item this copier made (read-only folders and
    /// locked items included), relative to its folder. Never follows
    /// symbolic links.
    static func removeTree(at dir: Int32, _ name: String) {
        var info = stat()
        guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd >= 0 {
                let folder = Directory(fd)
                if info.st_flags != 0 { _ = fchflags(fd, 0) }
                _ = fchmod(fd, 0o700)
                for child in entryNames(folder.fd) { removeTree(at: folder.fd, child) }
            }
            _ = unlinkat(dir, name, AT_REMOVEDIR)
        } else {
            if info.st_flags != 0 {
                let fd = openat(dir, name, O_EVTONLY | O_NOFOLLOW)
                if fd >= 0 {
                    _ = fchflags(fd, 0)
                    close(fd)
                } else if info.st_mode & S_IFMT == S_IFLNK {
                    let parent = Directory(dup(dir))
                    _ = lchflags(parent.path + "/" + name, 0)
                }
            }
            _ = unlinkat(dir, name, 0)
        }
    }

    static func removeTree(_ path: String) {
        let fd = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return }
        let parent = Directory(fd)
        removeTree(at: parent.fd, (path as NSString).lastPathComponent)
    }

    // MARK: stale temporaries

    /// Cleans up what an interrupted copy left in `directory`: temporary
    /// copies are deleted; an old item parked for the trash is put back
    /// when its name is free, or moved to the trash when the new item is
    /// in place. Items touched in the last `minimumAge` seconds, and
    /// folders taking part in a copy of this process, are left alone.
    /// Returns the names handled.
    @discardableResult
    public static func cleanStaleTemporaries(in directory: String, trash: any TrashMover,
                                             minimumAge: TimeInterval = 300) -> [String] {
        let canonical = FolderSession.canonical(directory)
        guard !CopyLock.shared.isHeld(canonical) else { return [] }
        let fd = open(canonical, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return [] }
        let folder = Directory(fd)
        let now = Date().timeIntervalSince1970
        var handled: [String] = []
        for name in entryNames(folder.fd) where name.hasPrefix(temporaryPrefix) {
            var info = stat()
            guard fstatat(folder.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
            guard now - changed >= minimumAge else { continue }
            if name.hasSuffix("-old") && info.st_mode & S_IFMT == S_IFDIR {
                let parkedFD = openat(folder.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard parkedFD >= 0 else { continue }
                let parked = Directory(parkedFD)
                for item in entryNames(parked.fd) {
                    if renameatx_np(parked.fd, item, folder.fd, item, UInt32(RENAME_EXCL)) != 0 {
                        _ = try? trash.trash(parked.path + "/" + item)
                    }
                }
                if unlinkat(folder.fd, name, AT_REMOVEDIR) == 0 { handled.append(name) }
            } else {
                removeTree(at: folder.fd, name)
                handled.append(name)
            }
        }
        return handled
    }

    /// Bytes of the regular files at or below `path`, without following
    /// symbolic links.
    static func treeSize(_ path: String, cancelled: Flag) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return UInt64(max(info.st_size, 0))
        case S_IFDIR:
            var total: UInt64 = 0
            for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                if cancelled.value { return total }
                total &+= treeSize(path + "/" + child, cancelled: cancelled)
            }
            return total
        default: return 0
        }
    }
}
