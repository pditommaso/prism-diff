// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin

/// Reads a command's input files.
///
/// Bytes are passed to the engine unchanged: decoding and line-ending
/// detection belong to a later milestone, so text is treated as UTF-8 only
/// when it is displayed or converted to UTF-16 columns.
///
/// Any readable file works, not only regular ones: FIFOs, process
/// substitution (`<(command)`, which names a `/dev/fd` pipe) and character
/// devices are read to their end. A lone `-` names standard input.
enum FileInput {

    /// Why a file could not be read; `message` reads well after "<path>: ".
    struct Failure: Error, Equatable {
        let path: String
        let message: String
    }

    /// The operand that names standard input.
    static let standardInputName = "-"

    /// Largest input accepted, in bytes. The engine stores line offsets as
    /// 32-bit integers.
    static let maximumSize = Int(Int32.max) - 1

    /// The contents of `path`. `-` reads `standardInput` to its end; a
    /// missing, unreadable or directory path is an error, reported with the
    /// system's reason.
    static func read(_ path: String, standardInput: Int32 = STDIN_FILENO,
                     maximumSize: Int = FileInput.maximumSize) throws(Failure) -> [UInt8] {
        if path == standardInputName {
            return try readAll(standardInput, path: path, sizeHint: 0, maximumSize: maximumSize)
        }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(path: path, errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure(path: path, errno: errno) }
        if info.st_mode & S_IFMT == S_IFDIR { throw Failure(path: path, errno: EISDIR) }
        let isRegular = info.st_mode & S_IFMT == S_IFREG
        if isRegular && Int(info.st_size) > maximumSize { throw tooLarge(path, maximumSize) }
        return try readAll(fd, path: path, sizeHint: isRegular ? Int(info.st_size) : 0,
                           maximumSize: maximumSize)
    }

    /// Reads `fd` until end of file. `sizeHint` is the expected size (the
    /// size of a regular file), used to read it in one allocation.
    private static func readAll(_ fd: Int32, path: String, sizeHint: Int,
                                maximumSize: Int) throws(Failure) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: max(sizeHint + 1, 64 << 10))
        var count = 0
        while true {
            if count == bytes.count {
                if count > maximumSize { throw tooLarge(path, maximumSize) }
                bytes.append(contentsOf: repeatElement(0, count: grownSize(count, maximumSize: maximumSize) - count))
            }
            let n = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + count, buffer.count - count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure(path: path, errno: errno)
            }
            if n == 0 { break }
            count += n
        }
        if count > maximumSize { throw tooLarge(path, maximumSize) }
        bytes.removeSubrange(count...)
        return bytes
    }

    /// The buffer size after a full buffer of `size` bytes, `size` at most
    /// `maximumSize`: double, but never past one byte over the limit, since
    /// reading that byte is enough to know the input is too big. An
    /// oversized stream thus never costs more than the limit plus one byte.
    static func grownSize(_ size: Int, maximumSize: Int) -> Int {
        min(size * 2, maximumSize + 1)
    }

    private static func tooLarge(_ path: String, _ maximumSize: Int) -> Failure {
        Failure(path: path, message: "file too large (the limit is \(maximumSize) bytes)")
    }
}

extension FileInput.Failure {
    init(path: String, errno code: Int32) {
        self.init(path: path, message: String(cString: strerror(code)))
    }
}
