// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation
import os
import PrismProtocol

/// The app end of the `prism` socket.
///
/// Listens on a Unix-domain socket (mode 0600 in a 0700 folder). The peer's
/// user ID is checked with getpeereid(2) as soon as a connection is
/// accepted, and a connection from any other user is closed without an
/// answer. The request is then read without blocking, by a read source on
/// the server's own queue, under one deadline for the whole request: an
/// idle or trickling client cannot hold a thread, and when
/// `maximumPendingRequests` connections are still sending, the oldest is
/// dropped to admit a new one. The complete `Request` frame is answered
/// through the `ChangesetRouter`. A request that waits keeps its connection until
/// the document closes (an `Event` frame is sent) or the client goes away.
///
/// Independent of AppKit: the app wires the router to its windows, tests to
/// a `RecordingSink`.
public final class IPCServer: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        /// Another server already answers on the socket path.
        case alreadyRunning(String)
        case socket(UnixSocket.Error)

        public var description: String {
            switch self {
            case .alreadyRunning(let path): "another instance already listens on \(path)"
            case .socket(let error): error.description
            }
        }
    }

    public let socketPath: String
    public let router: ChangesetRouter
    private let authorize: @Sendable (uid_t) -> Bool
    private let requestTimeout: Double
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketInode: ino_t = 0
    /// Connections held open by waiting clients, so that `stop()` can end
    /// them.
    private var waitingConnections: [ObjectIdentifier: WaitingConnection] = [:]
    private let acceptQueue = DispatchQueue(label: "\(PrismInfo.bundleIdentifier).ipc-accept")
    /// Reads requests and runs the router for them; never the global queues.
    private let connectionQueue = DispatchQueue(
        label: "\(PrismInfo.bundleIdentifier).ipc-connections", attributes: .concurrent)
    /// Connections still sending their request, oldest first.
    private var pending: [PendingRequest] = []
    private let maximumPendingRequests: Int
    private let securesDirectory: Bool

    /// - Parameters:
    ///   - authorize: decides from the peer's effective user ID whether it
    ///     may talk to the app; by default only the same user may.
    ///   - requestTimeout: how long a client may take to send its whole
    ///     request.
    ///   - maximumPendingRequests: connections allowed to be sending at
    ///     once; beyond it the oldest is dropped.
    ///   - securesDirectory: force the socket's folder to mode 0700 even
    ///     when it already exists (for the app's own Application Support
    ///     folder; never for an overridden path, which may be shared).
    public init(
        socketPath: String,
        router: ChangesetRouter,
        requestTimeout: Double = 5,
        maximumPendingRequests: Int = 32,
        securesDirectory: Bool = false,
        authorize: @escaping @Sendable (uid_t) -> Bool = { $0 == getuid() }
    ) {
        self.socketPath = socketPath
        self.router = router
        self.requestTimeout = requestTimeout
        self.maximumPendingRequests = maximumPendingRequests
        self.securesDirectory = securesDirectory
        self.authorize = authorize
    }

    deinit { stop() }

    /// Starts listening. Fails when another server answers on the path; a
    /// stale socket file left by a crashed instance is replaced.
    public func start() throws(StartError) {
        if IPCClient(socketPath: socketPath).isServerRunning(timeout: 1) {
            throw .alreadyRunning(socketPath)
        }
        let fd: Int32
        do {
            fd = try UnixSocket.listen(at: socketPath, securingDirectory: securesDirectory)
        } catch let error as UnixSocket.Error {
            throw .socket(error)
        } catch {
            throw .socket(.system(call: "listen", errno: EIO))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var info = stat()
        if stat(socketPath, &info) == 0 { socketInode = info.st_ino }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        lock.withLock {
            listener = fd
            acceptSource = source
        }
        source.resume()
    }

    /// Stops listening, removes the socket file (if it is still ours) and
    /// ends every waiting connection, which their clients see as the app
    /// going away.
    public func stop() {
        let (source, waiting, inode) = lock.withLock { () -> (DispatchSourceRead?, [ObjectIdentifier: WaitingConnection], ino_t) in
            let result = (acceptSource, waitingConnections, socketInode)
            acceptSource = nil
            waitingConnections = [:]
            listener = -1
            socketInode = 0
            return result
        }
        guard let source else { return }
        source.cancel()
        var info = stat()
        if inode != 0, stat(socketPath, &info) == 0, info.st_ino == inode {
            unlink(socketPath)
        }
        for connection in waiting.values {
            connection.close()
        }
        let unfinished = lock.withLock { pending }
        unfinished.forEach { $0.finish(nil) }
    }

    public var isRunning: Bool { lock.withLock { acceptSource != nil } }

    // MARK: - Connections

    private func acceptPending(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return      // EAGAIN: nothing more to accept
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard let uid = UnixSocket.peerUID(fd), authorize(uid) else {
                close(fd)
                continue
            }
            // Accepted sockets inherit O_NONBLOCK from the listener: the
            // request is read without blocking.
            startReading(fd)
        }
    }

    /// Reads one request frame from `fd` without blocking, within
    /// `requestTimeout` for the whole frame, then serves it.
    private func startReading(_ fd: Int32) {
        let request = PendingRequest(fd: fd)
        let evicted: PendingRequest? = lock.withLock {
            pending.append(request)
            return pending.count > maximumPendingRequests ? pending.removeFirst() : nil
        }
        evicted?.finish(nil)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: connectionQueue)
        source.setEventHandler { [weak request] in request?.readAvailable() }
        // Runs once the source is fully cancelled, so the descriptor is no
        // longer watched: serve the request or close the connection.
        source.setCancelHandler { [weak self, request] in
            self?.lock.withLock { self?.pending.removeAll { $0 === request } }
            guard let self, let frame = request.frame else {
                close(fd)
                return
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            UnixSocket.setTimeout(fd, seconds: self.requestTimeout)
            self.serve(fd, frame: frame)
        }
        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now() + requestTimeout)
        timer.setEventHandler { [weak request] in request?.finish(nil) }
        request.attach(source: source, timer: timer)
        timer.resume()
        source.resume()
    }

    private func serve(_ fd: Int32, frame: Data) {
        let request: Request
        do {
            request = try WireCoding.decode(Request.self, from: frame)
        } catch {
            PrismLog.ipc.error("unreadable request: \(String(describing: error), privacy: .public)")
            send(Reply.failure("unreadable request: \(error)"), on: fd)
            close(fd)
            return
        }

        guard request.operation == .open, request.invocation?.wait == true else {
            send(router.handle(request), on: fd)
            close(fd)
            return
        }

        let connection = WaitingConnection(fd: fd)
        let key = ObjectIdentifier(connection)
        let waiter = Waiter { [weak self] event in
            if let payload = try? WireCoding.encode(event) {
                connection.write(payload)
            }
            self?.endWaiting(key)
            connection.close()
        }
        let reply = router.handle(request, waiter: waiter)
        guard reply.ok, send(reply, on: fd) else {
            router.cancel(waiter)
            connection.close()
            return
        }
        UnixSocket.setTimeout(fd, seconds: 0)
        // The client sends nothing more: readability means it went away.
        let watch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        watch.setEventHandler { [weak self, weak waiter] in
            var byte: UInt8 = 0
            if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0 { return }
            if let waiter { self?.router.cancel(waiter) }
            self?.endWaiting(key)
            connection.close()
        }
        connection.attach(watch)
        lock.withLock { waitingConnections[key] = connection }
        watch.resume()
        waiter.arm()
    }

    private func endWaiting(_ key: ObjectIdentifier) {
        _ = lock.withLock { waitingConnections.removeValue(forKey: key) }
    }

    @discardableResult
    private func send(_ reply: Reply, on fd: Int32) -> Bool {
        guard let payload = try? WireCoding.encode(reply) else { return false }
        do {
            try Framing.write(payload, to: fd)
            return true
        } catch {
            return false
        }
    }
}

/// A connection held open for a waiting client. It is closed exactly once,
/// whichever of the event, the client's departure or the server's stop
/// comes first; once closed, nothing more is written to its descriptor
/// (whose number the system may already have reused).
private final class WaitingConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var watch: DispatchSourceRead?

    init(fd: Int32) { self.fd = fd }

    /// Hands over the read source watching the descriptor: from now on the
    /// descriptor is closed by the source's cancel handler, as dispatch
    /// requires.
    func attach(_ source: DispatchSourceRead) {
        let descriptor = fd
        source.setCancelHandler { Darwin.close(descriptor) }
        lock.withLock { watch = source }
    }

    func write(_ payload: Data) {
        lock.withLock {
            guard !closed else { return }
            try? Framing.write(payload, to: fd)
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            shutdown(fd, SHUT_RDWR)
            if let watch {
                watch.cancel()
            } else {
                Darwin.close(fd)
            }
        }
    }
}

/// A connection whose request is still arriving. `finish` ends it exactly
/// once, with the frame or with nil (end of file, a bad header, the
/// deadline, or eviction), by cancelling its read source.
private final class PendingRequest: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var finished = false
    private var result: Data?
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?

    init(fd: Int32) { self.fd = fd }

    func attach(source: DispatchSourceRead, timer: DispatchSourceTimer) {
        lock.withLock {
            self.source = source
            self.timer = timer
        }
    }

    /// The complete frame, once finished with one.
    var frame: Data? { lock.withLock { result } }

    func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let frames: [Data]
                do {
                    frames = try lock.withLock { try decoder.append(Data(buffer[..<count])) }
                } catch {
                    finish(nil)        // announced length over the limit
                    return
                }
                if let first = frames.first {
                    finish(first)
                    return
                }
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            finish(nil)                // end of file or error
            return
        }
    }

    func finish(_ frame: Data?) {
        let (source, timer) = lock.withLock { () -> (DispatchSourceRead?, DispatchSourceTimer?) in
            guard !finished else { return (nil, nil) }
            finished = true
            result = frame
            return (self.source, self.timer)
        }
        timer?.cancel()
        source?.cancel()
    }
}
