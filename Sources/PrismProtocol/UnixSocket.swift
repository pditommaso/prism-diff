// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Thin wrappers over AF_UNIX stream sockets.
public enum UnixSocket {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The path does not fit in `sockaddr_un.sun_path`.
        case pathTooLong(String)
        /// A system call failed with this errno.
        case system(call: String, errno: Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let path):
                "socket path is too long (\(path.utf8.count) bytes, at most \(UnixSocket.maximumPathLength)): \(path)"
            case .system(let call, let code):
                "\(call) failed: \(String(cString: strerror(code)))"
            }
        }

        /// True when nothing is listening at the path (no file, or a stale
        /// socket file whose server has gone).
        public var meansNoServer: Bool {
            if case .system("connect", let code) = self {
                return code == ENOENT || code == ECONNREFUSED
            }
            return false
        }
    }

    /// Longest path, in bytes, a socket address can hold.
    public static var maximumPathLength: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    }

    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else { throw Error.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.system(call: "socket", errno: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connects to the socket at `path`. Returns the connected descriptor.
    public static func connect(to path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Error.system(call: "connect", errno: code)
        }
        return fd
    }

    /// Creates the socket file at `path` (mode 0600; its directory is
    /// created with mode 0700 if needed) and listens on it. An existing file at
    /// the path is replaced; callers check first that no server answers.
    ///
    /// With `securingDirectory`, an existing directory is also set to 0700
    /// (only when the current user owns it).
    public static func listen(at path: String, backlog: Int32 = 128, securingDirectory: Bool = false) throws -> Int32 {
        var address = try address(path)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        if securingDirectory, stat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 != 0o700 {
            guard chmod(directory, 0o700) == 0 else { throw Error.system(call: "chmod", errno: errno) }
        }
        unlink(path)
        let fd = try makeSocket()
        // Not umask: it is process-wide and would race with other threads
        // creating files. Until the chmod below, the socket has the default
        // mode, which never grants write (connect) permission to others,
        // and peers are checked with getpeereid(2) anyway.
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Error.system(call: "bind", errno: code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Error.system(call: "chmod", errno: code)
        }
        guard Foundation.listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Error.system(call: "listen", errno: code)
        }
        return fd
    }

    /// The effective user ID of the process at the other end of `fd`.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// The PID of the process at the other end of `fd`.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
    }

    /// Sets the receive and send timeouts of `fd` (0 = none).
    public static func setTimeout(_ fd: Int32, seconds: Double) {
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }
}
