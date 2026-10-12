// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import os

/// A destination for command-line text output. The command-line tools write
/// through sinks so that tests can capture what would go to stdout/stderr.
///
/// Sinks made by `fileDescriptor(_:)` remember the first failed write (see
/// `failed`), so a tool can report it in its exit status instead of
/// pretending its output was delivered.
public struct TextSink: Sendable {
    private let writer: @Sendable (String) -> Void
    private let failure: WriteFailure?

    public init(_ writer: @escaping @Sendable (String) -> Void) {
        self.writer = writer
        self.failure = nil
    }

    private init(failure: WriteFailure, writer: @escaping @Sendable (String) -> Void) {
        self.writer = writer
        self.failure = failure
    }

    /// Writes `text` exactly as given (no newline is appended).
    public func write(_ text: String) {
        writer(text)
    }

    /// True once a write to the underlying file descriptor has failed.
    /// Always false for sinks built from a closure (such as test captures).
    public var failed: Bool { failure?.errorNumber != nil }

    /// The errno of the first failed write, or nil when none failed.
    public var failureErrno: Int32? { failure?.errorNumber }

    /// The process standard output (unbuffered).
    public static let standardOutput = fileDescriptor(STDOUT_FILENO)

    /// The process standard error (unbuffered).
    public static let standardError = fileDescriptor(STDERR_FILENO)

    /// A sink that writes UTF-8 text to an open file descriptor with
    /// write(2), retrying on EINTR and short writes.
    ///
    /// The first write error (a closed descriptor, EPIPE when SIGPIPE is
    /// ignored, a full disk) is recorded and makes `failed` true; the rest
    /// of that text and every later write are dropped without calling
    /// write(2) again. `FileHandle.write(_: Data)` is deliberately not
    /// used, because it raises an Objective-C exception on failure and
    /// aborts the process.
    public static func fileDescriptor(_ fd: Int32) -> TextSink {
        let failure = WriteFailure()
        return TextSink(failure: failure) { text in
            failure.performUnlessFailed {
                writeAll(fd, Array(text.utf8))
            }
        }
    }

    /// The exit status a tool should use after running a command that
    /// returned `status`: `writeFailureStatus` when `stdout` failed (its
    /// output did not reach the reader), otherwise `status` unchanged.
    ///
    /// When stdout failed, one diagnostic naming `program` is written to
    /// `stderr` on a best-effort basis (it is dropped if stderr is broken
    /// too). Never traps or raises a signal.
    public static func exitStatus(
        _ status: Int32,
        stdout: TextSink,
        stderr: TextSink,
        program: String,
        writeFailureStatus: Int32
    ) -> Int32 {
        guard let code = stdout.failureErrno else { return status }
        stderr.write("\(program): cannot write to standard output: \(String(cString: strerror(code)))\n")
        return writeFailureStatus
    }

    /// Writes every byte to `fd`. Returns nil on success, or the errno of
    /// the first write(2) failure other than EINTR.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int32? {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
    }
}

/// The first write failure of a file-descriptor sink, shared by all copies
/// of that sink and safe to use from any thread.
final class WriteFailure: Sendable {
    private let state = OSAllocatedUnfairLock<Int32?>(initialState: nil)

    var errorNumber: Int32? { state.withLock { $0 } }

    /// Runs `body` unless a failure was already recorded; records the errno
    /// it returns. The lock is held during `body`, which also keeps
    /// concurrent writes to the same sink from interleaving.
    func performUnlessFailed(_ body: () -> Int32?) {
        state.withLockUnchecked { recorded in
            guard recorded == nil else { return }
            recorded = body()
        }
    }
}
