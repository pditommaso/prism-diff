// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Length-prefixed frames: a 4-byte big-endian payload length followed by
/// the payload (one JSON message).
public enum Framing {
    /// Largest accepted payload. A 5,000-file changeset is about 2 MB.
    public static let maximumPayload = 64 * 1024 * 1024
    public static let headerSize = 4

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The peer closed the connection before a whole frame arrived.
        case closed
        /// The announced length exceeds `maximumPayload`.
        case tooLarge(Int)
        /// read(2) or write(2) failed with this errno.
        case io(Int32)
        /// No complete frame arrived in time.
        case timedOut

        public var description: String {
            switch self {
            case .closed: "connection closed"
            case .tooLarge(let n): "frame of \(n) bytes exceeds the \(Framing.maximumPayload)-byte limit"
            case .io(let code): "socket error: \(String(cString: strerror(code)))"
            case .timedOut: "timed out"
            }
        }
    }

    /// The bytes of one frame carrying `payload`.
    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maximumPayload else { throw Error.tooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: headerSize)
        out.append(payload)
        return out
    }

    /// Decodes the payload length from a 4-byte header.
    public static func payloadLength(header: Data) throws -> Int {
        precondition(header.count == headerSize)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maximumPayload else { throw Error.tooLarge(length) }
        return length
    }

    /// Writes one frame to `fd`, retrying short writes and EINTR.
    public static func write(_ payload: Data, to fd: Int32) throws {
        let bytes = try frame(payload)
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? Error.timedOut : Error.io(errno)
                }
                offset += written
            }
        }
    }

    /// Reads one frame from `fd`. Throws `.closed` on end of file.
    public static func read(from fd: Int32) throws -> Data {
        let header = try readExactly(headerSize, from: fd)
        return try readExactly(payloadLength(header: header), from: fd)
    }

    private static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        guard count > 0 else { return data }
        try data.withUnsafeMutableBytes { buffer in
            let base = buffer.baseAddress!
            var offset = 0
            while offset < count {
                let n = Foundation.read(fd, base + offset, count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? Error.timedOut : Error.io(errno)
                }
                if n == 0 { throw Error.closed }
                offset += n
            }
        }
        return data
    }
}

/// Splits a byte stream into frames, for readers that receive data in
/// arbitrary chunks.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends received bytes and returns every frame now complete.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= Framing.headerSize {
            let start = buffer.startIndex
            let length = try Framing.payloadLength(header: buffer[start..<start + Framing.headerSize])
            let end = start + Framing.headerSize + length
            guard buffer.count >= Framing.headerSize + length else { break }
            frames.append(Data(buffer[(start + Framing.headerSize)..<end]))
            buffer = Data(buffer[end...])
        }
        return frames
    }

    /// Bytes received that do not yet form a whole frame.
    public var pendingByteCount: Int { buffer.count }
}
