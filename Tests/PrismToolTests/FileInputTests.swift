// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation
import PrismTestSupport
import Testing
@testable import PrismTool

/// `FileInput`: regular files, pipes, FIFOs, standard input and errors.
@Suite struct FileInputTests {

    /// A pipe whose write end is fed `bytes` from another thread, so inputs
    /// bigger than the pipe buffer work too. Returns the read end.
    static func pipeFeeding(_ bytes: [UInt8]) -> Int32 {
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        let writeEnd = fds[1]
        // A reader that stops early must not kill the test process.
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        Thread.detachNewThread {
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress! + offset, bytes.count - offset) }
                if n <= 0 { break }
                offset += n
            }
            close(writeEnd)
        }
        return fds[0]
    }

    @Test func regularFileIsReadWhole() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let bytes = (0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let url = dir.url.appending(path: "f")
        try Data(bytes).write(to: url)
        #expect(try FileInput.read(url.path(percentEncoded: false)) == bytes)
    }

    @Test func emptyFileAndDevNullAreEmpty() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.url.appending(path: "empty")
        try Data().write(to: url)
        #expect(try FileInput.read(url.path(percentEncoded: false)).isEmpty)
        #expect(try FileInput.read("/dev/null").isEmpty)
    }

    @Test func dashReadsStandardInputToTheEnd() throws {
        let bytes = Array(String(repeating: "line of standard input\n", count: 20_000).utf8)
        let fd = Self.pipeFeeding(bytes)
        defer { close(fd) }
        #expect(try FileInput.read("-", standardInput: fd) == bytes)
    }

    @Test func pipeNamedByDevFdIsRead() throws {
        // What `<(command)` hands over: a /dev/fd path naming a pipe.
        let bytes = Array("from a process substitution\n".utf8)
        let fd = Self.pipeFeeding(bytes)
        defer { close(fd) }
        #expect(try FileInput.read("/dev/fd/\(fd)") == bytes)
    }

    @Test func namedFIFOIsRead() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let path = dir.url.appending(path: "fifo").path(percentEncoded: false)
        #expect(mkfifo(path, 0o600) == 0)
        let bytes = Array("through a fifo\n".utf8)
        Thread.detachNewThread {
            let fd = open(path, O_WRONLY)
            guard fd >= 0 else { return }
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, bytes.count) }
            close(fd)
        }
        #expect(try FileInput.read(path) == bytes)
    }

    @Test func errorsCarryTheSystemReason() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let missing = dir.url.appending(path: "missing").path(percentEncoded: false)
        #expect(throws: FileInput.Failure(path: missing, message: "No such file or directory")) {
            try FileInput.read(missing)
        }
        let directory = dir.url.path(percentEncoded: false)
        #expect(throws: FileInput.Failure(path: directory, message: "Is a directory")) {
            try FileInput.read(directory)
        }
        let locked = dir.url.appending(path: "locked")
        try Data("x".utf8).write(to: locked)
        chmod(locked.path(percentEncoded: false), 0)
        if geteuid() != 0 {
            #expect(throws: FileInput.Failure(path: locked.path(percentEncoded: false), message: "Permission denied")) {
                try FileInput.read(locked.path(percentEncoded: false))
            }
        }
    }

    @Test func inputsOverTheLimitAreRefused() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.url.appending(path: "big")
        try Data(repeating: 65, count: 1000).write(to: url)
        let path = url.path(percentEncoded: false)
        #expect(throws: FileInput.Failure.self) { try FileInput.read(path, maximumSize: 999) }
        #expect(try FileInput.read(path, maximumSize: 1000).count == 1000)
        // A pipe has no size up front: the limit applies while reading.
        let fd = Self.pipeFeeding([UInt8](repeating: 66, count: 300_000))
        defer { close(fd) }
        #expect(throws: FileInput.Failure.self) { try FileInput.read("-", standardInput: fd, maximumSize: 100_000) }
        // A stream of exactly the limit is accepted.
        let exact = Self.pipeFeeding([UInt8](repeating: 67, count: 100_000))
        defer { close(exact) }
        #expect(try FileInput.read("-", standardInput: exact, maximumSize: 100_000).count == 100_000)
    }

    @Test func streamBufferNeverGrowsPastTheLimit() {
        // Doubling a 1 GiB buffer would allocate 2 GiB (and 4 GiB on the
        // next step) before an oversized stream is refused.
        let limit = FileInput.maximumSize
        #expect(FileInput.grownSize(64 << 10, maximumSize: limit) == 128 << 10)
        #expect(FileInput.grownSize(1 << 30, maximumSize: limit) == limit + 1)
        #expect(FileInput.grownSize(limit, maximumSize: limit) == limit + 1)
    }
}
