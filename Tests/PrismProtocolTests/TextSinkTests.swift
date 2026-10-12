// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import Testing
import PrismProtocol

@Suite struct TextSinkTests {
    /// Creates a pipe; returns (read end, write end).
    private func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }

    @Test func writesTextToTheDescriptor() throws {
        let (readEnd, writeEnd) = try makePipe()
        defer { close(readEnd) }
        let text = "héllo\n" + String(repeating: "x", count: 10_000)
        TextSink.fileDescriptor(writeEnd).write(text)
        close(writeEnd)
        let data = FileHandle(fileDescriptor: readEnd).readDataToEndOfFile()
        #expect(String(decoding: data, as: UTF8.self) == text)
    }

    /// Reads everything left in `fd` until EOF.
    private func drain(_ fd: Int32) -> String {
        String(decoding: FileHandle(fileDescriptor: fd).readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func successfulWriteLeavesFailedFalse() throws {
        let (readEnd, writeEnd) = try makePipe()
        defer { close(readEnd) }
        let sink = TextSink.fileDescriptor(writeEnd)
        sink.write("ok\n")
        close(writeEnd)
        #expect(!sink.failed)
        #expect(sink.failureErrno == nil)
        #expect(drain(readEnd) == "ok\n")
    }

    /// A broken pipe with SIGPIPE suppressed makes write(2) fail with
    /// EPIPE. FileHandle.write(_: Data) raised an uncaught exception there
    /// and aborted the whole process; the sink must record it and return.
    @Test func brokenPipeIsRecordedWithoutAbort() throws {
        let (readEnd, writeEnd) = try makePipe()
        defer { close(writeEnd) }
        // Per-descriptor: no process-wide signal disposition change.
        try #require(fcntl(writeEnd, F_SETNOSIGPIPE, 1) == 0)
        close(readEnd)
        let sink = TextSink.fileDescriptor(writeEnd)
        sink.write("lost\n")
        #expect(sink.failed)
        #expect(sink.failureErrno == EPIPE)
    }

    /// The same for an invalid descriptor (EBADF), as with `prism >&-`.
    @Test func closedDescriptorIsRecordedWithoutAbort() {
        let sink = TextSink.fileDescriptor(-1)
        sink.write("lost\n")
        #expect(sink.failed)
        #expect(sink.failureErrno == EBADF)
    }

    /// Once failed, the sink stops calling write(2): text written after a
    /// working pipe replaces the same descriptor number never reaches it.
    /// The descriptor stays open throughout (dup2 swaps it atomically), so
    /// tests running in parallel cannot be handed that number meanwhile.
    @Test func noWritesAfterFailure() throws {
        let (brokenRead, fd) = try makePipe()
        defer { close(fd) }
        try #require(fcntl(fd, F_SETNOSIGPIPE, 1) == 0)
        close(brokenRead)
        let sink = TextSink.fileDescriptor(fd)
        sink.write("lost\n")
        try #require(sink.failureErrno == EPIPE)

        let (readEnd, writeEnd) = try makePipe()
        defer { close(readEnd) }
        try #require(dup2(writeEnd, fd) == fd)
        close(writeEnd)
        sink.write("must not appear\n")
        // Prove the reopened descriptor works, then end the stream.
        let probe = TextSink.fileDescriptor(fd)
        probe.write("probe")
        try #require(!probe.failed)
        let devNull = open("/dev/null", O_WRONLY)
        try #require(devNull >= 0)
        defer { close(devNull) }
        try #require(dup2(devNull, fd) == fd)
        #expect(drain(readEnd) == "probe")
        #expect(sink.failureErrno == EPIPE)
    }

    @Test func capturingSinksNeverFail() {
        let sink = TextSink { _ in }
        sink.write("x")
        #expect(!sink.failed)
    }

    @Test func exitStatusKeepsCommandStatusWhenStdoutWorked() throws {
        let (readEnd, writeEnd) = try makePipe()
        defer { close(readEnd); close(writeEnd) }
        let stdout = TextSink.fileDescriptor(writeEnd)
        stdout.write("fine\n")
        let stderr = Captured()
        for status: Int32 in [0, 1, 7] {
            #expect(TextSink.exitStatus(status, stdout: stdout, stderr: stderr.sink,
                                        program: "tool", writeFailureStatus: 2) == status)
        }
        #expect(stderr.text == "")
    }

    @Test func exitStatusReportsStdoutFailure() {
        let stdout = TextSink.fileDescriptor(-1)
        stdout.write("lost\n")
        let stderr = Captured()
        #expect(TextSink.exitStatus(0, stdout: stdout, stderr: stderr.sink,
                                    program: "tool", writeFailureStatus: 2) == 2)
        #expect(stderr.text.hasPrefix("tool: cannot write to standard output: "))
        #expect(stderr.text.hasSuffix("\n"))
    }

    @Test func exitStatusSurvivesBrokenStderr() {
        let stdout = TextSink.fileDescriptor(-1)
        stdout.write("lost\n")
        let stderr = TextSink.fileDescriptor(-1)
        #expect(TextSink.exitStatus(1, stdout: stdout, stderr: stderr,
                                    program: "tool", writeFailureStatus: 2) == 2)
    }
}

/// Minimal thread-safe capture (PrismTestSupport is not a dependency of
/// every assertion here, and this keeps the test self-contained).
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    var text: String { lock.withLock { buffer } }
    var sink: TextSink { TextSink { [self] chunk in lock.withLock { buffer += chunk } } }
}
