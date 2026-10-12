// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin
import FolderCore
import Foundation

/// Folder-comparison harness: rows of a level, a generated large tree, the
/// scan budgets and the live-refresh latency.
enum FolderBench {
    static let usage = """
        folder commands:
          folders [opts] LEFT RIGHT        print the rows of one level and the counts
              --path REL                   the level to show (default: the roots)
              --hidden                     include hidden files
              --contents                   confirm changed files by their contents
              --method automatic|bulk|fts  listing interface (default automatic)
          foldergen DIR [--dirs N] [--files N]
                                           write DIR/left and DIR/right: N files in N dirs
                                           (default 20000 dirs, 200000 files); the right side
                                           is a clone with mutations in 14 of 20 top folders.
                                           Reuses DIR when its manifest matches.
          folderperf [opts] LEFT RIGHT     first-rows and deep-pass times, peak RSS
              --runs N                     timed runs after one warm-up (default 3)
              --first-rows-ms MS           budget for the first rows (default 50)
              --deep-ms MS                 budget for the deep pass (default 2000)
              --rss-mb MB                  budget for the peak RSS (default 150)
              --scale F                    multiplies the time budgets (default 1)
              --expect C,U,M               expected changed, unchanged, unmatched root counts
          folderwatch [opts] LEFT RIGHT --touch REL
                                           touch REL (a file below RIGHT or LEFT) and time
                                           the update of its row; fails on a full rescan
              --budget-ms MS               budget (default 200)
              --repeat N                   touches (default 5); the worst one is checked
        \(CopyBench.usage)
        """

    static func run(_ command: String, _ arguments: [String]) -> Int32 {
        if command == "foldercopy" { return CopyBench.run(arguments) }
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        let valued: Set<String> = ["--path", "--method", "--dirs", "--files", "--runs", "--first-rows-ms",
                                   "--deep-ms", "--rss-mb", "--scale", "--expect", "--touch", "--budget-ms",
                                   "--repeat"]
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if valued.contains(argument) {
                guard let value = iterator.next() else { usageError("\(argument) needs a value") }
                options[argument] = value
            } else if argument == "--hidden" || argument == "--contents" {
                flags.insert(argument)
            } else if argument.hasPrefix("-") {
                usageError("unknown option \(argument)")
            } else {
                positional.append(argument)
            }
        }
        var folderOptions = FolderOptions(includeHidden: flags.contains("--hidden"),
                                          compareContents: flags.contains("--contents"))
        if let method = options["--method"] {
            guard let parsed = ScanMethod(rawValue: method) else { usageError("unknown method \(method)") }
            folderOptions.method = parsed
        }
        let report = BenchReport()
        switch command {
        case "folders":
            guard positional.count == 2 else { usageError("folders needs LEFT and RIGHT") }
            return printLevel(positional[0], positional[1], path: options["--path"] ?? "", options: folderOptions)
        case "foldergen":
            guard positional.count == 1 else { usageError("foldergen needs DIR") }
            generate(positional[0], directories: parseNumber(options["--dirs"] ?? "20000", "--dirs", minimum: 20),
                     files: parseNumber(options["--files"] ?? "200000", "--files", minimum: 1), report: report)
        case "folderperf":
            guard positional.count == 2 else { usageError("folderperf needs LEFT and RIGHT") }
            let scale: Double = parseNumber(options["--scale"] ?? "1", "--scale", minimum: 0.000_001)
            perf(positional[0], positional[1], options: folderOptions,
                 runs: parseNumber(options["--runs"] ?? "3", "--runs", minimum: 1),
                 firstRowsMs: parseNumber(options["--first-rows-ms"] ?? "50", "--first-rows-ms", minimum: 0.0) * scale,
                 deepMs: parseNumber(options["--deep-ms"] ?? "2000", "--deep-ms", minimum: 0.0) * scale,
                 rssMB: parseNumber(options["--rss-mb"] ?? "150", "--rss-mb", minimum: 1.0),
                 expect: options["--expect"], report: report)
        case "folderwatch":
            guard positional.count == 2, let touch = options["--touch"] else {
                usageError("folderwatch needs LEFT RIGHT --touch REL")
            }
            watch(positional[0], positional[1], touch: touch, options: folderOptions,
                  budgetMs: parseNumber(options["--budget-ms"] ?? "200", "--budget-ms", minimum: 1.0),
                  repeats: parseNumber(options["--repeat"] ?? "5", "--repeat", minimum: 1), report: report)
        default:
            usageError("unknown command \(command)")
        }
        print("checks=\(report.checks) failures=\(report.failures)")
        return report.exitStatus
    }

    // MARK: folders

    /// One line per row: status, left name (or "-"), right name (or "-"),
    /// left size, right size; then the counts.
    static func printLevel(_ left: String, _ right: String, path: String, options: FolderOptions) -> Int32 {
        let level = FolderSession.compare(left: left, right: right, relativePath: path, options: options)
        for row in level.rows {
            let sizes = [row.left, row.right].map { $0.map { FolderFormat.size($0.size) } ?? "-" }
            let newer = row.status == .changed && row.newer != .none ? " (\(row.newer.rawValue) newer)" : ""
            print("\(row.status.rawValue)\t\(row.left?.name ?? "-")\t\(row.right?.name ?? "-")\t\(sizes[0])\t\(sizes[1])\(newer)")
        }
        let counts = level.counts
        print("counts changed=\(counts.changed) unchanged=\(counts.unchanged) unmatched=\(counts.unmatched)"
            + (level.leftMissing ? " left-missing" : "") + (level.rightMissing ? " right-missing" : ""))
        return 0
    }

    // MARK: folderperf

    static func perf(_ left: String, _ right: String, options: FolderOptions, runs: Int, firstRowsMs: Double,
                     deepMs: Double, rssMB: Double, expect: String?, report: BenchReport) {
        var firstRows: [Double] = [], deep: [Double] = []
        var level: FolderLevel?
        var statistics = FolderStatistics()
        for run in 0...runs {
            let start = nowMs()
            let session = FolderSession(left: left, right: right, options: options)
            let shallow = session.level("")
            let shallowMs = nowMs() - start
            let deepStart = nowMs()
            session.start(watch: false)
            session.waitUntilScanned()
            let final = session.level("")
            let deepTotal = nowMs() - deepStart
            statistics = session.currentStatistics
            session.stop()
            precondition(!shallow.rows.isEmpty || final.rows.isEmpty)
            level = final
            if run > 0 {
                firstRows.append(shallowMs)
                deep.append(deepTotal)
            }
        }
        let rss = Double(peakRSS()) / 1_048_576
        let medianFirst = median(firstRows), medianDeep = median(deep)
        report.info(["directories": "\(statistics.directories)", "methods": statistics.methods.joined(separator: "/"),
                     "workers": "\(options.workers)"])
        report.record(medianFirst <= firstRowsMs, "first rows: median \(formatMs(medianFirst)) ms (budget \(formatMs(firstRowsMs)) ms)",
                      fields: ["check": "first-rows", "median_ms": formatMs(medianFirst),
                               "min_ms": formatMs(firstRows.min() ?? 0), "budget_ms": formatMs(firstRowsMs)])
        report.record(medianDeep <= deepMs, "deep pass: median \(formatMs(medianDeep)) ms (budget \(formatMs(deepMs)) ms)",
                      fields: ["check": "deep-pass", "median_ms": formatMs(medianDeep),
                               "min_ms": formatMs(deep.min() ?? 0), "budget_ms": formatMs(deepMs)])
        report.record(rss <= rssMB, "peak RSS: \(String(format: "%.1f", rss)) MB (budget \(String(format: "%.0f", rssMB)) MB)",
                      fields: ["check": "rss", "rss_mb": String(format: "%.1f", rss), "budget_mb": String(format: "%.0f", rssMB)])
        if let level {
            let counts = level.counts
            let text = "\(counts.changed),\(counts.unchanged),\(counts.unmatched)"
            report.info(["counts": text, "complete": "\(level.isComplete)"])
            if let expect {
                report.record(text == expect && level.isComplete, "root counts \(text) (expected \(expect))")
            }
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    static func peakRSS() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss   // bytes on macOS
    }

    // MARK: folderwatch

    static func watch(_ left: String, _ right: String, touch: String, options: FolderOptions, budgetMs: Double,
                      repeats: Int, report: BenchReport) {
        let lines = Lines()
        let session = FolderSession(left: left, right: right, options: options) { line in
            lines.append(line)
            print("log: \(line)")
        }
        defer { session.stop() }
        session.start()
        session.waitUntilScanned()
        let side: Side, relative: String
        let target: String
        let rightRoot = session.rightPath, leftRoot = session.leftPath
        let absolute = URL(filePath: touch.hasPrefix("/") ? touch : rightRoot + "/" + touch).standardizedFileURL
            .path(percentEncoded: false)
        let resolved = FolderSessionPaths.canonical(absolute)
        if resolved.hasPrefix(rightRoot + "/") {
            side = .right
            relative = String(resolved.dropFirst(rightRoot.count + 1))
        } else if resolved.hasPrefix(leftRoot + "/") {
            side = .left
            relative = String(resolved.dropFirst(leftRoot.count + 1))
        } else {
            report.record(false, "\(touch) is not inside either root")
            return
        }
        target = resolved
        let levelPath = (relative as NSString).deletingLastPathComponent
        let name = (relative as NSString).lastPathComponent
        let updates = Updates()
        let queue = DispatchQueue(label: "folderwatch")
        let observation = session.observe(levelPath, on: queue) { updates.add($0) }
        defer { observation.cancel() }
        guard updates.wait(timeout: 30, { $0.isComplete }) != nil else {
            report.record(false, "level '\(levelPath)' never completed")
            return
        }
        Thread.sleep(forTimeInterval: 0.3)   // let the FSEvents stream settle
        var worst = 0.0
        var latencies: [Double] = []
        for index in 0..<repeats {
            let before = updates.last?.row(name)?.entry(side)?.modificationTimeNs ?? 0
            let start = nowMs()
            var times = [timespec(tv_sec: Int(time(nil)) + index + 1, tv_nsec: 0),
                         timespec(tv_sec: Int(time(nil)) + index + 1, tv_nsec: 0)]
            guard utimensat(AT_FDCWD, target, &times, 0) == 0 else {
                report.record(false, "cannot touch \(target): \(String(cString: strerror(errno)))")
                return
            }
            let seen = updates.wait(timeout: 5) { ($0.row(name)?.entry(side)?.modificationTimeNs ?? before) != before }
            let ms = nowMs() - start
            guard seen != nil else {
                report.record(false, "touch \(index + 1): no row update within 5 s")
                return
            }
            latencies.append(ms)
            worst = max(worst, ms)
            Thread.sleep(forTimeInterval: 0.15)
        }
        let statistics = session.currentStatistics
        report.record(worst <= budgetMs,
                      "row update after touch: worst \(formatMs(worst)) ms of \(repeats) (budget \(formatMs(budgetMs)) ms)",
                      fields: ["check": "touch-latency", "worst_ms": formatMs(worst),
                               "median_ms": formatMs(median(latencies)), "budget_ms": formatMs(budgetMs)])
        report.record(statistics.fullScans == 1 && statistics.incrementalRefreshes >= repeats,
                      "no full rescan: \(statistics.fullScans) full scan, \(statistics.incrementalRefreshes) incremental refreshes",
                      fields: ["check": "no-rescan", "full_scans": "\(statistics.fullScans)",
                               "incremental": "\(statistics.incrementalRefreshes)"])
        let logged = lines.all
        report.record(logged.filter { $0.contains("full scan started") }.count == 1
                        && logged.contains { $0.contains("incremental refresh") && $0.contains("no full rescan") },
                      "log shows one full scan and incremental refreshes only")
    }

    // MARK: foldergen

    /// Writes a deterministic left/right pair. Files hold zeros (their size
    /// is set with ftruncate): the scan reads metadata only.
    static func generate(_ directory: String, directories: Int, files: Int, report: BenchReport) {
        let root = URL(filePath: directory, directoryHint: .isDirectory)
        let manifestURL = root.appending(path: "manifest.txt")
        let manifest = "prism-foldergen v1 dirs=\(directories) files=\(files)\n"
        if (try? String(contentsOf: manifestURL, encoding: .utf8)) == manifest {
            report.record(true, "reusing \(directory) (\(manifest.trimmingCharacters(in: .newlines)))")
            return
        }
        let start = nowMs()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: root)
        let left = root.appending(path: "left", directoryHint: .isDirectory)
        let right = root.appending(path: "right", directoryHint: .isDirectory)
        var random = SplitMix(seed: 42)
        let baseTime = 1_700_000_000
        let tops = (0..<20).map { String(format: "top%02d", $0) }
        var dirs = tops
        var frontier = tops
        var seen = Set(dirs)
        while dirs.count < directories {
            let parent = frontier[Int(random.next() % UInt64(frontier.count))]
            let path = parent + "/" + String(format: "d%06d", random.next() % 1_000_000)
            guard seen.insert(path).inserted else { continue }
            dirs.append(path)
            if path.split(separator: "/").count < 7 { frontier.append(path) }
        }
        do {
            for dir in dirs { try fileManager.createDirectory(at: left.appending(path: dir), withIntermediateDirectories: true) }
        } catch {
            report.record(false, "cannot create directories: \(error)")
            return
        }
        let extensions = [".c", ".h", ".txt", ".json", ".png", ".md", ".swift", ".o", "", ".dat"]
        var plan: [(path: String, size: Int, time: Int)] = []
        plan.reserveCapacity(files)
        for index in 0..<files {
            let dir = dirs[Int(random.next() % UInt64(dirs.count))]
            let ext = extensions[Int(random.next() % UInt64(extensions.count))]
            // Log-normal-ish sizes: median about 2 KB, capped at 8 MB.
            let size = min(8 << 20, Int(exp(7.6 + 1.6 * random.gaussian())))
            plan.append((dir + "/file\(index)" + ext, size, baseTime + Int(random.next() % 10_000_000)))
        }
        let leftPath = left.path(percentEncoded: false)
        let failures = Counter()
        let plannedFiles = plan
        DispatchQueue.concurrentPerform(iterations: 16) { worker in
            var index = worker
            while index < plannedFiles.count {
                let item = plannedFiles[index]
                if !writeFile(leftPath + "/" + item.path, size: item.size, time: item.time) { failures.add() }
                index += 16
            }
        }
        // Symlinks, hidden files and .DS_Store files.
        for index in 0..<300 {
            let dir = dirs[Int(random.next() % UInt64(dirs.count))]
            let target = plan[Int(random.next() % UInt64(plan.count))].path
            _ = symlink(target, leftPath + "/" + dir + "/link\(index)")
        }
        for index in 0..<400 {
            let dir = dirs[Int(random.next() % UInt64(dirs.count))]
            _ = writeFile(leftPath + "/" + dir + "/.hidden\(index)", size: 100, time: baseTime)
        }
        for index in stride(from: 0, to: dirs.count, by: 10) {
            _ = writeFile(leftPath + "/" + dirs[index] + "/.DS_Store", size: 6148, time: baseTime)
        }
        for dir in dirs { setTime(leftPath + "/" + dir, baseTime) }
        guard failures.value == 0 else {
            report.record(false, "\(failures.value) files could not be written")
            return
        }
        // The right side: an APFS clone (cp -c), then mutations confined to
        // top00-top13, so top14-top19 stay unchanged.
        let copy = Process()
        copy.executableURL = URL(filePath: "/bin/cp")
        copy.arguments = ["-cRp", leftPath, right.path(percentEncoded: false)]
        do {
            try copy.run()
            copy.waitUntilExit()
        } catch {
            report.record(false, "cp failed: \(error)")
            return
        }
        guard copy.terminationStatus == 0 else {
            report.record(false, "cp -cRp exited \(copy.terminationStatus)")
            return
        }
        let rightPath = right.path(percentEncoded: false)
        let mutable = plan.indices.filter { index in
            let top = plan[index].path.prefix(5)
            return top < "top14"
        }
        var order = mutable
        for index in stride(from: order.count - 1, to: 0, by: -1) {
            order.swapAt(index, Int(random.next() % UInt64(index + 1)))
        }
        var cursor = order.makeIterator()
        let later = baseTime + 20_000_000
        var counts: [String: Int] = [:]
        for step in 0..<(files / 50) {             // 2%: content changes, newer
            guard let index = cursor.next() else { break }
            let item = plan[index]
            _ = writeFile(rightPath + "/" + item.path, size: step % 2 == 0 ? item.size : item.size + 1 + step % 499, time: later)
            counts["changed", default: 0] += 1
        }
        for _ in 0..<(files / 200) {               // 0.5%: touched only
            guard let index = cursor.next() else { break }
            setTime(rightPath + "/" + plan[index].path, later + 1)
            counts["touched", default: 0] += 1
        }
        for _ in 0..<(files / 200) {               // 0.5%: removed
            guard let index = cursor.next() else { break }
            unlink(rightPath + "/" + plan[index].path)
            counts["removed", default: 0] += 1
        }
        let mutableDirs = dirs.filter { $0.prefix(5) < "top14" }
        for index in 0..<(files / 200) {           // 0.5%: added
            let dir = mutableDirs[Int(random.next() % UInt64(mutableDirs.count))]
            _ = writeFile(rightPath + "/" + dir + "/added\(index).txt", size: 1 + Int(random.next() % 20_000), time: later)
            counts["added", default: 0] += 1
        }
        let deep = mutableDirs.filter { $0.contains("/") }
        for index in 0..<50 {                      // new folders
            let dir = deep[Int(random.next() % UInt64(deep.count))] + "/newdir\(index)"
            try? fileManager.createDirectory(atPath: rightPath + "/" + dir, withIntermediateDirectories: true)
            for file in 0..<5 { _ = writeFile(rightPath + "/" + dir + "/n\(file).txt", size: 1000, time: later) }
        }
        var removedDirs = 0
        for _ in 0..<50 {                          // removed folders
            let dir = deep[Int(random.next() % UInt64(deep.count))]
            if (try? fileManager.removeItem(atPath: rightPath + "/" + dir)) != nil { removedDirs += 1 }
        }
        _ = writeFile(rightPath + "/ROOT_ADDED.txt", size: 1, time: later)
        let summary = "dirs=\(dirs.count) files=\(files) changed=\(counts["changed"] ?? 0) touched=\(counts["touched"] ?? 0) "
            + "removed=\(counts["removed"] ?? 0) added=\(counts["added"] ?? 0) removed-dirs=\(removedDirs)"
        do {
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch {
            report.record(false, "cannot write the manifest: \(error)")
            return
        }
        report.record(true, "generated \(directory) in \(formatMs((nowMs() - start) / 1000)) s: \(summary)")
    }

    static func writeFile(_ path: String, size: Int, time: Int) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        if fd < 0 { return false }
        defer { close(fd) }
        if ftruncate(fd, off_t(size)) != 0 { return false }
        var times = [timespec(tv_sec: time, tv_nsec: 0), timespec(tv_sec: time, tv_nsec: 0)]
        return futimens(fd, &times) == 0
    }

    static func setTime(_ path: String, _ time: Int) {
        var times = [timespec(tv_sec: time, tv_nsec: 0), timespec(tv_sec: time, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }
}

/// realpath, for matching paths against the session's resolved roots.
enum FolderSessionPaths {
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Deterministic generator (SplitMix64) with a Gaussian helper.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal sample (Box-Muller).
    mutating func gaussian() -> Double {
        let u = max(unit(), 1e-12), v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Level updates received by an observer, with a blocking wait.
final class Updates: @unchecked Sendable {
    private let condition = NSCondition()
    private var levels: [FolderLevel] = []

    func add(_ level: FolderLevel) {
        condition.lock()
        levels.append(level)
        condition.broadcast()
        condition.unlock()
    }

    var last: FolderLevel? {
        condition.lock()
        defer { condition.unlock() }
        return levels.last
    }

    func wait(timeout: TimeInterval, _ predicate: (FolderLevel) -> Bool) -> FolderLevel? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let level = levels.last, predicate(level) { return level }
            if !condition.wait(until: deadline) { return nil }
        }
    }
}

extension FolderLevel {
    func row(_ name: String) -> FolderRow? { rows.first { $0.name == name } }
}
