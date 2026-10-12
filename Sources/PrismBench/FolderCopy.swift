// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import FolderCore
import Foundation

/// `foldercopy`: stages items the way the folder window does and runs the
/// copy engine, printing every step. Replaced items always go to a plain
/// directory (--trash), never to the Finder Trash.
enum CopyBench {
    static let usage = """
        foldercopy [opts] LEFT RIGHT     stage items from the current rows and copy them
              --to-right REL               stage REL (a path below both roots) to the right;
              --to-left REL                or to the left; both repeatable
              --trash DIR                  where replaced items go (required)
              --on-error skip|stop|retry   answer to every error (default skip; retry tries
                                           once more, then skips)
              --cancel-after-mb N          cancel once N MiB are copied
              --no-clone                   always copy bytes (no APFS clones)
        """

    static func run(_ arguments: [String]) -> Int32 {
        var stages: [(String, CopyDirection)] = []
        var trash: String?, onError = "skip", cancelAfter: UInt64?, allowClone = true
        var positional: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--to-right", "--to-left":
                guard let value = iterator.next() else { usageError("\(argument) needs a path") }
                stages.append((value, argument == "--to-right" ? .toRight : .toLeft))
            case "--trash":
                trash = iterator.next()
            case "--on-error":
                guard let value = iterator.next(), ["skip", "stop", "retry"].contains(value) else {
                    usageError("--on-error takes skip, stop or retry")
                }
                onError = value
            case "--cancel-after-mb":
                cancelAfter = UInt64(parseNumber(iterator.next(), "--cancel-after-mb", minimum: 1)) << 20
            case "--no-clone":
                allowClone = false
            default:
                if argument.hasPrefix("-") { usageError("unknown option \(argument)") }
                positional.append(argument)
            }
        }
        guard positional.count == 2 else { usageError("foldercopy needs LEFT and RIGHT") }
        guard let trash else { usageError("foldercopy needs --trash DIR") }
        guard !stages.isEmpty else { usageError("foldercopy needs --to-right or --to-left") }
        let (left, right) = (positional[0], positional[1])

        var items: [StagedCopy] = []
        for (path, direction) in stages {
            let level = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let rows = FolderSession.compare(left: left, right: right, relativePath: level).rows
            guard let row = rows.first(where: { $0.name == name }) else {
                print("FAIL  no row named \(path)")
                return 1
            }
            var staging = FolderStaging(levelPath: level)
            staging.set(row, direction)
            guard let item = staging.ordered.first else {
                print("FAIL  \(path) (\(row.status.rawValue)) cannot be copied \(direction.rawValue)")
                return 1
            }
            print("staged \(item.relativePath) \(direction.rawValue)\(item.replaces ? " replace" : "") \(item.size) bytes")
            items.append(item)
        }

        let copier = FolderCopier(leftRoot: left, rightRoot: right, items: items,
                                  trash: DirectoryTrash(directory: trash), allowClone: allowClone)
        if case .failure(let conflict) = CopyLock.shared.acquire(copier.lockPaths) {
            print("FAIL  busy: \(conflict.path)")
            return 1
        }
        var retried: Set<String> = []
        var lastFraction = -1.0
        let outcome = copier.run(progress: { progress in
            if let cancelAfter, progress.completedBytes >= cancelAfter, !copier.isCancelled {
                print("cancel at \(progress.completedBytes) of \(progress.totalBytes) bytes")
                copier.cancel()
            }
            let fraction = (progress.fraction * 4).rounded(.down) / 4
            if fraction != lastFraction {
                lastFraction = fraction
                print("progress \(progress.phase.rawValue) \(progress.name) \(Int(fraction * 100))%")
            }
        }, onError: { failure in
            print("error \(failure.relativePath) code=\(failure.code) \(failure.title) \(failure.reason)")
            switch onError {
            case "stop": return .stop
            case "retry" where !retried.contains(failure.relativePath):
                retried.insert(failure.relativePath)
                return .retry
            default: return .skip
            }
        })
        for path in outcome.copied { print("copied \(path)") }
        for path in outcome.skipped { print("skipped \(path)") }
        for path in outcome.notAttempted { print("not-attempted \(path)") }
        for (path, place) in outcome.trashed.sorted(by: { $0.key < $1.key }) { print("trashed \(path) -> \(place)") }
        print("outcome copied=\(outcome.copied.count) skipped=\(outcome.skipped.count) "
            + "cancelled=\(outcome.cancelled) stopped=\(outcome.stopped) bytes=\(outcome.copiedBytes)")
        return 0
    }
}
