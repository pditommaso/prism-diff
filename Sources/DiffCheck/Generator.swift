// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// Random text files and edits for property testing the diff engine.
///
/// Files are built from a small vocabulary with heavy duplication, blank
/// lines, braces, tabs, non-ASCII words, trailing blanks, CRLF, lone CR,
/// mixed line endings and missing final newlines. Edits insert, delete, change a word, re-indent, add
/// trailing blanks, move blocks and replace lines.
public enum CaseGenerator {
    static let vocabulary = [
        "let", "var", "x", "y", "foo", "bar", "return", "{", "}", "(", ")", "=", "+",
        "if", "else", "Ünï", "naïve", "42", "_tmp", ";", ",", "\"s\"",
    ]

    /// One random line, without terminator.
    public static func randomLine(_ rng: inout SplitMix64) -> String {
        if Int.random(in: 0 ..< 8, using: &rng) == 0 {
            return ["", "}", "{", "    }"].randomElement(using: &rng)!
        }
        let indent = String(repeating: " ", count: 4 * Int.random(in: 0 ... 3, using: &rng))
        let words = (0 ..< Int.random(in: 1 ... 7, using: &rng)).map { _ in
            vocabulary.randomElement(using: &rng)!
        }
        let separator = [" ", " ", " ", "\t", ""].randomElement(using: &rng)!
        let trailing = Int.random(in: 0 ..< 10, using: &rng) == 0 ? "  " : ""
        return indent + words.joined(separator: separator) + trailing
    }

    /// `count` random lines.
    public static func randomLines(_ count: Int, _ rng: inout SplitMix64) -> [String] {
        (0 ..< count).map { _ in randomLine(&rng) }
    }

    /// Applies 0 to 12 random edits.
    public static func mutate(_ lines: [String], _ rng: inout SplitMix64) -> [String] {
        var b = lines
        let edits = Int.random(in: 0 ... 12, using: &rng)
        for _ in 0 ..< edits {
            let operation = Int.random(in: 0 ..< 7, using: &rng)
            let i = b.isEmpty ? 0 : Int.random(in: 0 ..< b.count, using: &rng)
            switch operation {
            case 0:
                b.insert(randomLine(&rng), at: min(i, b.count))
            case 1:
                if !b.isEmpty { b.remove(at: i) }
            case 2:
                // Replace one space-separated word.
                if !b.isEmpty {
                    var words = b[i].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                    if !words.isEmpty {
                        words[Int.random(in: 0 ..< words.count, using: &rng)] = vocabulary.randomElement(using: &rng)!
                    }
                    b[i] = words.joined(separator: " ")
                }
            case 3:
                if !b.isEmpty { b[i] = "  " + b[i] }
            case 4:
                if !b.isEmpty { b[i] += " \t" }
            case 5:
                // Move a block of 1 to 3 lines.
                if b.count > 4 {
                    let n = Int.random(in: 1 ... 3, using: &rng)
                    let j = min(i, b.count - n)
                    let chunk = Array(b[j ..< j + n])
                    b.removeSubrange(j ..< j + n)
                    b.insert(contentsOf: chunk, at: Int.random(in: 0 ... b.count, using: &rng))
                }
            default:
                if !b.isEmpty { b[i] = randomLine(&rng) }
            }
        }
        return b
    }

    /// Joins lines with a terminator drawn at random for each line from LF,
    /// CRLF and lone CR, optionally ending with a final terminator.
    public static func joinMixed(_ lines: [String], finalNewline: Bool, _ rng: inout SplitMix64) -> [UInt8] {
        var bytes: [UInt8] = []
        for (i, line) in lines.enumerated() {
            bytes += Array(line.utf8)
            if i < lines.count - 1 || finalNewline {
                bytes += Array(["\n", "\r\n", "\r"].randomElement(using: &rng)!.utf8)
            }
        }
        return bytes
    }

    /// Line endings of one side of a case: mostly LF, sometimes CRLF, lone
    /// CR or a mix within the file. `salt` keeps the two sides apart.
    static func encode(_ lines: [String], iteration: Int, salt: Int, finalNewline: Bool,
                       _ rng: inout SplitMix64) -> [UInt8] {
        let k = iteration + salt
        if k % 7 == 0 { return join(lines, eol: "\r\n", finalNewline: finalNewline) }
        if k % 13 == 0 { return join(lines, eol: "\r", finalNewline: finalNewline) }
        if k % 17 == 0 { return joinMixed(lines, finalNewline: finalNewline, &rng) }
        return join(lines, eol: "\n", finalNewline: finalNewline)
    }

    /// Joins lines with `eol`, optionally ending with a final terminator.
    public static func join(_ lines: [String], eol: String, finalNewline: Bool) -> [UInt8] {
        var text = lines.joined(separator: eol)
        if finalNewline && !lines.isEmpty { text += eol }
        return Array(text.utf8)
    }
}

/// A pair of inputs and the options to diff them with.
public struct PropertyCase: Sendable {
    public var a: [UInt8]
    public var b: [UInt8]
    /// Options without the whitespace mode, which every case runs in all
    /// three variants.
    public var options: DiffOptions

    public init(a: [UInt8], b: [UInt8], options: DiffOptions) {
        self.a = a
        self.b = b
        self.options = options
    }
}

/// The two passes of a property run.
public enum PropertyPass: String, Sendable, CaseIterable {
    /// Default options; files of 0 to 200 lines.
    case defaults
    /// Every heuristic forced on: cost cap at sqrt(N), pre-pairing on every
    /// block and, for some cases, a tiny refinement valve. Files of 0 to 600
    /// lines with more edits and some wholesale region replacements, which
    /// exercise the discard path.
    case forcedHeuristics

    /// The case for one iteration of this pass.
    public func makeCase(iteration: Int, _ rng: inout SplitMix64) -> PropertyCase {
        let a: [String]
        var b: [String]
        var options = DiffOptions()
        switch self {
        case .defaults:
            a = CaseGenerator.randomLines(Int.random(in: 0 ... 200, using: &rng), &rng)
            b = CaseGenerator.mutate(a, &rng)
        case .forcedHeuristics:
            a = CaseGenerator.randomLines(Int.random(in: 0 ... 600, using: &rng), &rng)
            b = CaseGenerator.mutate(CaseGenerator.mutate(CaseGenerator.mutate(a, &rng), &rng), &rng)
            if iteration % 4 == 0 {
                let n = Int.random(in: 40 ... 80, using: &rng)
                let j = Int.random(in: 0 ... max(b.count - n, 0), using: &rng)
                b.replaceSubrange(j ..< min(j + n, b.count), with: CaseGenerator.randomLines(n, &rng))
            }
            options.myersMinCost = 1
            options.prePairBytes = 1
            if iteration % 5 == 1 { options.maxRefineTokens = 200 }
        }
        let bytesA = CaseGenerator.encode(a, iteration: iteration, salt: 0, finalNewline: iteration % 5 != 0, &rng)
        let bytesB = CaseGenerator.encode(b, iteration: iteration, salt: 4, finalNewline: iteration % 3 != 0, &rng)
        return PropertyCase(a: bytesA, b: bytesB, options: options)
    }
}
