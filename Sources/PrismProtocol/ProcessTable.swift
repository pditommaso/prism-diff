// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// One process as reported by the kernel.
public struct ProcessRecord: Sendable, Hashable {
    public var identity: ProcessIdentity
    public var parentPID: Int32
    /// Short command name (at most 16 bytes), such as `git` or `sh`.
    public var name: String

    public init(identity: ProcessIdentity, parentPID: Int32, name: String) {
        self.identity = identity
        self.parentPID = parentPID
        self.name = name
    }

    public var pid: Int32 { identity.pid }
}

/// Read-only access to the process table through sysctl(3).
public enum ProcessTable {
    /// The record of `pid`, or nil when no such process exists.
    public static func record(of pid: Int32) -> ProcessRecord? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessRecord(
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: Int64(start.tv_sec),
                startMicroseconds: Int32(start.tv_usec)
            ),
            parentPID: info.kp_eproc.e_ppid,
            name: name
        )
    }

    /// The argument vector of `pid` (KERN_PROCARGS2), or nil when it cannot
    /// be read (another user's process, or the process has gone).
    public static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        return parseProcargs(Array(buffer[..<size]))
    }

    /// Parses a KERN_PROCARGS2 buffer: argc (Int32), the executable path,
    /// NUL padding, then argc NUL-terminated arguments.
    static func parseProcargs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0..<4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }    // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }    // padding
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    /// True while the process `identity` names is still running (same PID
    /// and same start time).
    public static func isRunning(_ identity: ProcessIdentity) -> Bool {
        record(of: identity.pid)?.identity == identity
    }

    /// Ancestors of `pid`, nearest first, starting with `pid`'s parent.
    public static func ancestors(of pid: Int32 = getpid(), limit: Int = 64) -> [ProcessRecord] {
        var result: [ProcessRecord] = []
        var current = record(of: pid)?.parentPID ?? getppid()
        while current > 1, result.count < limit, let record = record(of: current) {
            result.append(record)
            current = record.parentPID
        }
        return result
    }
}

/// Finds the version-control process on whose behalf `prism` runs.
public enum CallerDetection {
    /// The tool a process belongs to, from its short name and arguments.
    /// Mercurial and Bazaar are Python scripts, so their process name is the
    /// interpreter's and the script name is in the arguments.
    public static func tool(name: String, arguments: [String]?) -> VersionControlTool? {
        switch name {
        case "git": return .git
        case "svn": return .subversion
        case "p4": return .perforce
        case "hg": return .mercurial
        case "bzr": return .bazaar
        default: break
        }
        guard name.lowercased().hasPrefix("python"), let arguments else { return nil }
        for argument in arguments.dropFirst().prefix(3) {
            switch (argument as NSString).lastPathComponent {
            case "hg": return .mercurial
            case "bzr": return .bazaar
            default: continue
            }
        }
        return nil
    }

    /// The nearest version-control ancestor of the current process, or its
    /// immediate parent when no ancestor is a version-control tool.
    public static func caller(
        ancestors: [ProcessRecord] = ProcessTable.ancestors(),
        arguments: (Int32) -> [String]? = ProcessTable.arguments(of:),
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) -> CallerInfo {
        for record in ancestors {
            let needsArguments = record.name.lowercased().hasPrefix("python")
            let args = needsArguments ? arguments(record.pid) : nil
            if let tool = tool(name: record.name, arguments: args) {
                return CallerInfo(
                    process: record.identity,
                    name: record.name,
                    arguments: args ?? arguments(record.pid) ?? [],
                    tool: tool,
                    workingDirectory: workingDirectory
                )
            }
        }
        guard let parent = ancestors.first else {
            return CallerInfo(process: nil, name: "", arguments: [], tool: .unknown,
                              workingDirectory: workingDirectory)
        }
        return CallerInfo(
            process: parent.identity,
            name: parent.name,
            arguments: arguments(parent.pid) ?? [],
            tool: .unknown,
            workingDirectory: workingDirectory
        )
    }
}
