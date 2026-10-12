// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// The client side of the app socket: one request per connection.
public struct IPCClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public enum Failure: Error, CustomStringConvertible {
        /// Nothing listens at the socket path.
        case notRunning
        /// Connecting, sending or receiving failed.
        case transport(String)
        /// The reply could not be decoded.
        case badReply(String)

        public var description: String {
            switch self {
            case .notRunning: "the app is not running"
            case .transport(let message): message
            case .badReply(let message): "unreadable reply: \(message)"
            }
        }
    }

    /// An open connection whose request has been answered; used to wait for
    /// the document's `Event`.
    public final class Connection: @unchecked Sendable {
        public let fd: Int32
        private let lock = NSLock()
        private var closed = false

        init(fd: Int32) { self.fd = fd }

        deinit { close() }

        /// Blocks until the app sends the event or the connection ends.
        /// Throws `Framing.Error.closed` when the app went away.
        public func waitForEvent() throws -> Event {
            UnixSocket.setTimeout(fd, seconds: 0)
            let data = try Framing.read(from: fd)
            return try WireCoding.decode(Event.self, from: data)
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            // shutdown wakes a thread blocked reading the socket.
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    /// Sends `request` and returns the reply. When `keepOpen` is true the
    /// connection is returned too, for `Connection.waitForEvent()`.
    public func send(
        _ request: Request,
        timeout: Double = 30,
        keepOpen: Bool = false
    ) throws(Failure) -> (Reply, Connection?) {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath)
        } catch let error as UnixSocket.Error where error.meansNoServer {
            throw .notRunning
        } catch {
            throw .transport("cannot connect to \(socketPath): \(error)")
        }
        let connection = Connection(fd: fd)
        UnixSocket.setTimeout(fd, seconds: timeout)
        let data: Data
        do {
            try Framing.write(try WireCoding.encode(request), to: fd)
            data = try Framing.read(from: fd)
        } catch {
            connection.close()
            throw .transport("lost the connection to the app: \(error)")
        }
        let reply: Reply
        do {
            reply = try WireCoding.decode(Reply.self, from: data)
        } catch {
            connection.close()
            throw .badReply("\(error)")
        }
        if keepOpen {
            return (reply, connection)
        }
        connection.close()
        return (reply, nil)
    }

    /// True when an app answers a ping right now.
    public func isServerRunning(timeout: Double = 2) -> Bool {
        guard let (reply, _) = try? send(Request(operation: .ping), timeout: timeout) else { return false }
        return reply.ok
    }
}
