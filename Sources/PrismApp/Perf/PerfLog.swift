// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import Foundation

/// Optional performance log for benchmarks and acceptance scripts. When the
/// environment variable `PRISM_PERF_LOG` names a file, events are appended
/// to it as JSON lines; otherwise nothing is recorded.
@MainActor
enum PerfLog {
    static let path: String? = {
        let value = ProcessInfo.processInfo.environment["PRISM_PERF_LOG"]
        return value?.isEmpty == false ? value : nil
    }()

    static var isEnabled: Bool { path != nil }

    /// Appends `{"event": name, ...fields}` as one line.
    static func record(_ name: String, _ fields: [String: Any] = [:]) {
        guard let path else { return }
        var object = fields
        object["event"] = name
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Milliseconds since this process was created (kernel start time, so
    /// it includes dynamic loading and AppKit start-up).
    static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }

    /// Resident memory of this process, in MB.
    static func residentMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1_048_576
    }

    static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// Watches the main thread while a comparison loads: a repeating timer on
/// the main run loop notes the longest gap between its ticks. A blocked main
/// thread shows up as one long gap.
@MainActor
final class MainThreadStallMonitor {
    private var timer: Timer?
    private var last = DispatchTime.now().uptimeNanoseconds
    private(set) var longestGapMilliseconds: Double = 0

    func start() {
        last = DispatchTime.now().uptimeNanoseconds
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        longestGapMilliseconds = max(longestGapMilliseconds, Double(now - last) / 1e6)
        last = now
    }

    func stop() {
        tick()
        timer?.invalidate()
        timer = nil
    }
}
