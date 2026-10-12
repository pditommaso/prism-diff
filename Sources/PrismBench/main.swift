// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

// PrismBench: release-mode engine bench and cross-checks. Internal tool,
// never shipped in Prism.app (scripts/bundle.sh copies only the app, prism
// and prism executables).
//
// Every subcommand prints a PASS/FAIL line per check and a machine-readable
// line of key=value pairs, and exits 0 only when every check passed.

import DiffCheck
import DiffCore
import Foundation

let usage = """
    usage: PrismBench <command> [options]

    commands:
      perf [--scale F] [--repeat N]   median engine time per corpus case against its budget
                                      (budgets are multiplied by F, default 1; N timed runs
                                      after one warm-up, default 5)
      property [N]                    N iterations x 3 whitespace modes x 2 passes (default 5000)
      cancel                          latency from cancel() to return on diff20k, m1 and
                                      synthetic disjoint, long-line and one-line pairs
      gitcheck                        line-hunk counts against git diff --no-index --patience -U0
      folders, foldergen, folderperf, folderwatch
                                      folder comparison harness (see below)

    options:
      --corpus DIR                    the Tests/corpus directory (default: found from the
                                      current directory, or PRISM_CORPUS_DIR)

    \(FolderBench.usage)
    """

/// Command-line errors: message on stderr, exit status 2.
func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("PrismBench: \(message)\n\(usage)\n".utf8))
    exit(2)
}

func parseNumber<T: LosslessStringConvertible & Comparable>(_ text: String?, _ name: String, minimum: T) -> T {
    guard let text, let value = T(text), value >= minimum else {
        usageError("\(name) needs a number of at least \(minimum)")
    }
    return value
}

func benchMain(_ arguments: [String]) -> Int32 {
    guard let command = arguments.first else { usageError("missing command") }
    if command == "--help" || command == "-h" || command == "help" {
        print(usage)
        return 0
    }
    if command.hasPrefix("folder") {
        return FolderBench.run(command, Array(arguments.dropFirst()))
    }
    var scale = 1.0, repeats = 5, iterations = 5000
    var corpusOverride: String?
    var rest = arguments.dropFirst().makeIterator()
    var positional: [String] = []
    while let argument = rest.next() {
        switch argument {
        case "--scale": scale = parseNumber(rest.next(), "--scale", minimum: 0.000_001)
        case "--repeat": repeats = parseNumber(rest.next(), "--repeat", minimum: 1)
        case "--corpus":
            guard let directory = rest.next() else { usageError("--corpus needs a directory") }
            corpusOverride = directory
        default:
            if argument.hasPrefix("-") { usageError("unknown option \(argument)") }
            positional.append(argument)
        }
    }
    if command == "property", let count = positional.first {
        iterations = parseNumber(count, "property", minimum: 1)
        positional.removeFirst()
    }
    if !positional.isEmpty { usageError("unexpected argument \(positional[0])") }

    let report = BenchReport()
    if command == "property" {
        let start = nowMs()
        let result = PropertyRunner.run(iterations: iterations)
        let elapsed = (nowMs() - start) / 1000
        for detail in result.failureDetails { print("  \(detail)") }
        report.record(result.failures == 0 && result.cases == iterations * 6,
                      "property: \(result.cases) cases, \(result.failures) failures, "
                          + "seed \(PropertyRunner.defaultSeed), \(String(format: "%.1f", elapsed)) s")
        print("cases=\(result.cases) failures=\(result.failures)")
        return report.exitStatus
    }

    guard ["perf", "cancel", "gitcheck"].contains(command) else { usageError("unknown command \(command)") }
    guard let corpus = BenchCorpus.locate(override: corpusOverride) else {
        report.record(false, "cannot find Tests/corpus: run from the repository or pass --corpus DIR")
        return report.exitStatus
    }
    switch command {
    case "perf": PerfBench.run(corpus: corpus, scale: scale, repeats: repeats, report: report)
    case "cancel": CancelBench.run(corpus: corpus, report: report)
    default: GitCheckBench.run(corpus: corpus, report: report)
    }
    print("checks=\(report.checks) failures=\(report.failures)")
    return report.exitStatus
}

setvbuf(stdout, nil, _IOLBF, 0)
exit(benchMain(Array(CommandLine.arguments.dropFirst())))
