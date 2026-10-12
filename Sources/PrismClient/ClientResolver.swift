// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import PrismProtocol

/// Turns parsed arguments into the `Invocation` sent to the app: absolute
/// paths, placeholders for missing sides, statuses, relative paths and the
/// temporary-file decision. Folder pairs given to `--changeset` are
/// expanded into one file list per file found on either side.
struct ClientResolver {
    var workingDirectory: String
    var temporaryRule: TemporaryFileRule
    private let fileManager = FileManager.default

    init(workingDirectory: String, temporaryRule: TemporaryFileRule) {
        self.workingDirectory = workingDirectory
        self.temporaryRule = temporaryRule
    }

    func invocation(for open: OpenArguments, caller: CallerInfo) throws(UsageError) -> Invocation {
        Invocation(
            kind: open.kind,
            fileLists: try fileLists(for: open),
            label: open.label,
            changesetUUID: open.changesetUUID,
            wait: open.waits,
            caller: caller,
            mergeOutput: try open.output.map { path throws(UsageError) in try mergeOutput(path) }
        )
    }

    /// The absolute `--output` path. The file may be missing (the app
    /// creates it when the result is saved, never before), but its folder
    /// must exist, and a folder is refused.
    func mergeOutput(_ path: String) throws(UsageError) -> String {
        let output = absolute(path)
        if isDirectory(output) { throw UsageError("\(path): is a folder, not a file") }
        let folder = (output as NSString).deletingLastPathComponent
        guard isDirectory(folder) else { throw UsageError("\(path): no such folder for the output file") }
        return output
    }

    func fileLists(for open: OpenArguments) throws(UsageError) -> [FileList] {
        switch open.kind {
        case .diff:
            let files = try open.fileLists[0].files.map { file throws(UsageError) in
                try reference(file, mustExist: true)
            }
            return [FileList(files: files)]
        case .partialChangeset:
            let list = open.fileLists[0]
            let files = try list.files.map { file throws(UsageError) in try reference(file, mustExist: false) }
            return [FileList(
                files: files,
                status: list.status ?? Self.status(of: files),
                relativePath: list.relativePath ?? defaultRelativePath(files)
            )]
        case .changeset:
            var result: [FileList] = []
            for list in open.fileLists {
                result += try expand(list)
            }
            return result
        case .merge:
            // A, B, then the base when there is one.
            var files = try open.fileLists[0].files.map { file throws(UsageError) in
                try reference(file, mustExist: true)
            }
            if let base = open.base { files.append(try reference(base, mustExist: true)) }
            if files.contains(where: { isDirectory($0.path) }) {
                throw UsageError("only files can be merged, not folders")
            }
            let row = open.output.map { defaultRelativePath([FileReference(path: absolute($0), temporary: false)]) } ?? nil
            return [FileList(files: files, relativePath: row)]
        }
    }

    // MARK: - Paths

    func absolute(_ path: String) -> String {
        if path == IPCProtocol.placeholderPath { return path }
        let joined = path.hasPrefix("/") ? path : (workingDirectory as NSString).appendingPathComponent(path)
        return (joined as NSString).standardizingPath
    }

    private func reference(_ file: ParsedFile, mustExist: Bool) throws(UsageError) -> FileReference {
        let path = absolute(file.path)
        if path == IPCProtocol.placeholderPath {
            return FileReference(path: path, temporary: false)
        }
        guard fileManager.fileExists(atPath: path) else {
            if mustExist { throw UsageError("\(file.path): no such file or directory") }
            return FileReference(path: IPCProtocol.placeholderPath, temporary: false)
        }
        // Only regular files are ever copied (never a whole folder).
        var info = stat()
        let regular = stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        return FileReference(path: path, temporary: regular && (file.snapshot ?? temporaryRule.isTemporary(path)))
    }

    static func status(of files: [FileReference]) -> FileStatus {
        if files.first?.isPlaceholder == true { return .added }
        if files.last?.isPlaceholder == true { return .removed }
        return .changed
    }

    /// The row name when no `--relative-path` was given: the path of the
    /// newer side relative to the working directory when it lies inside
    /// it, otherwise its file name.
    func defaultRelativePath(_ files: [FileReference]) -> String? {
        guard let file = files.last(where: { !$0.isPlaceholder }) else { return nil }
        let base = workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/"
        if file.path.hasPrefix(base) {
            return String(file.path.dropFirst(base.count))
        }
        return (file.path as NSString).lastPathComponent
    }

    // MARK: - Folder pairs

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Relative paths of the regular files below `root`, in no order.
    private func files(under root: String) -> Set<String> {
        var result = Set<String>()
        guard let enumerator = fileManager.enumerator(atPath: root) else { return result }
        while let relative = enumerator.nextObject() as? String {
            if !isDirectory((root as NSString).appendingPathComponent(relative)) {
                result.insert(relative)
            }
        }
        return result
    }

    private func expand(_ list: ParsedFileList) throws(UsageError) -> [FileList] {
        let left = absolute(list.files[0].path)
        let right = absolute(list.files[1].path)
        let leftIsFolder = isDirectory(left)
        let rightIsFolder = isDirectory(right)
        guard leftIsFolder || rightIsFolder else {
            let files = try list.files.map { file throws(UsageError) in try reference(file, mustExist: false) }
            return [FileList(
                files: files,
                status: list.status ?? Self.status(of: files),
                relativePath: list.relativePath ?? defaultRelativePath(files)
            )]
        }
        guard leftIsFolder || !fileManager.fileExists(atPath: left),
              rightIsFolder || !fileManager.fileExists(atPath: right) else {
            throw UsageError("cannot compare a folder with a file in one --filelist")
        }
        let leftFiles = leftIsFolder ? files(under: left) : []
        let rightFiles = rightIsFolder ? files(under: right) : []
        return leftFiles.union(rightFiles).sorted().map { relative in
            let pair = [
                ParsedFile(path: (left as NSString).appendingPathComponent(relative), snapshot: list.files[0].snapshot),
                ParsedFile(path: (right as NSString).appendingPathComponent(relative), snapshot: list.files[1].snapshot),
            ]
            // Neither side can be missing in a way that throws: mustExist is false.
            let files = pair.map { (try? reference($0, mustExist: false)) ?? FileReference(path: IPCProtocol.placeholderPath, temporary: false) }
            let row = list.relativePath.map { ($0 as NSString).appendingPathComponent(relative) } ?? relative
            return FileList(files: files, status: Self.status(of: files), relativePath: row)
        }
    }
}
