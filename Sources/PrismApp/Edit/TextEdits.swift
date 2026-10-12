// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// What a merge does with one change of a two-way comparison. The arrows
/// say where the text goes: "to the right" writes into B, "to the left"
/// into A.
enum MergeChoice: String, Sendable, CaseIterable {
    /// B's lines become A's (⌘→).
    case copyToRight
    /// A's lines become B's (⌘←).
    case copyToLeft
    /// B's lines become A's followed by B's (⌥⌘→).
    case keepBothLeftFirst
    /// A's lines become B's followed by A's (⌥⌘←).
    case keepBothRightFirst

    /// The side whose text changes.
    var destination: DiffSide {
        switch self {
        case .copyToRight, .keepBothLeftFirst: .b
        case .copyToLeft, .keepBothRightFirst: .a
        }
    }

    /// Menu title and undo action name.
    var title: String {
        switch self {
        case .copyToRight: "Copy to Right"
        case .copyToLeft: "Copy to Left"
        case .keepBothLeftFirst: "Keep Both (Left then Right)"
        case .keepBothRightFirst: "Keep Both (Right then Left)"
        }
    }

    /// The lines of each side after the choice, from the original lines
    /// of the change. Lines are concatenated as they are; `joined` adds a
    /// terminator between two parts when the first one lacks it.
    func result(a: [UInt8], b: [UInt8]) -> (a: [UInt8], b: [UInt8]) {
        switch self {
        case .copyToRight: (a, a)
        case .copyToLeft: (b, b)
        case .keepBothLeftFirst: (a, LineText.joined(a, b))
        case .keepBothRightFirst: (LineText.joined(b, a), b)
        }
    }
}

/// Line-level helpers over UTF-8 text whose lines end in LF, CRLF or a lone
/// CR (the same rules as the diff engine).
enum LineText {
    /// Start offsets of every line followed by the length (so empty text
    /// has zero lines).
    static func starts(_ bytes: [UInt8]) -> [Int] {
        var starts = [0]
        var i = 0
        let n = bytes.count
        while i < n {
            let byte = bytes[i]
            i += 1
            if byte == 0x0A {
                starts.append(i)
            } else if byte == 0x0D {
                if i < n, bytes[i] == 0x0A { i += 1 }
                starts.append(i)
            }
        }
        if starts[starts.count - 1] != n { starts.append(n) }
        return starts
    }

    /// Number of lines, counting an unterminated last one.
    static func lineCount(_ bytes: [UInt8]) -> Int { starts(bytes).count - 1 }

    /// True when `bytes` is empty or ends with a line terminator.
    static func endsWithTerminator(_ bytes: [UInt8]) -> Bool {
        guard let last = bytes.last else { return true }
        return last == 0x0A || last == 0x0D
    }

    /// The terminator to use for new lines in `bytes`: the most common one,
    /// LF when there is none.
    static func terminator(of bytes: [UInt8]) -> [UInt8] {
        var lf = 0, crlf = 0, cr = 0
        var i = 0
        let n = bytes.count
        while i < n {
            if bytes[i] == 0x0A {
                lf += 1
            } else if bytes[i] == 0x0D {
                if i + 1 < n, bytes[i + 1] == 0x0A {
                    crlf += 1
                    i += 1
                } else {
                    cr += 1
                }
            }
            i += 1
        }
        if crlf > lf && crlf >= cr { return [0x0D, 0x0A] }
        if cr > lf && cr > crlf { return [0x0D] }
        return [0x0A]
    }

    /// `first` then `second`, with LF (or `first`'s own terminator) added
    /// between them when `first` does not end a line.
    static func joined(_ first: [UInt8], _ second: [UInt8]) -> [UInt8] {
        guard !first.isEmpty, !second.isEmpty, !endsWithTerminator(first) else { return first + second }
        return first + terminator(of: first + second) + second
    }

    /// Line breaks of pasted or typed text as plain "\n": CR LF, a lone CR
    /// and the Unicode line and paragraph separators.
    static func normalizingBreaks(_ text: String) -> String {
        guard text.contains(where: { $0 == "\r" || $0 == "\r\n" || $0 == "\u{2028}" || $0 == "\u{2029}" })
        else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "\r\n", "\r", "\u{2028}", "\u{2029}": out.append("\n")
            default: out.append(character)
            }
        }
        return out
    }

    /// The terminators of each line of `bytes`, in order (an unterminated
    /// last line gives an empty one).
    static func terminators(_ bytes: [UInt8]) -> [[UInt8]] {
        let starts = starts(bytes)
        return (0 ..< starts.count - 1).map { i in
            let end = starts[i + 1]
            var from = end
            if from > starts[i], bytes[from - 1] == 0x0A { from -= 1 }
            if from > starts[i], bytes[from - 1] == 0x0D { from -= 1 }
            return Array(bytes[from ..< end])
        }
    }

    /// Edited lines (`typed`, lines separated by "\n") written back over
    /// `original`: line k keeps the terminator line k had, so a file with
    /// mixed endings keeps them; lines beyond the original count take
    /// `terminator`.
    static func retyped(_ typed: String, original: [UInt8], terminator: [UInt8]) -> [UInt8] {
        let text = normalizingBreaks(typed)
        let kept = terminators(original)
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count + 16)
        var line = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                let own = line < kept.count && !kept[line].isEmpty ? kept[line] : terminator
                out.append(contentsOf: own)
                line += 1
            } else {
                out.append(byte)
            }
        }
        return out
    }

    /// Text typed in the editor (lines separated by "\n") with the
    /// terminators of the file it goes into.
    static func converting(_ typed: String, terminator: [UInt8]) -> [UInt8] {
        let bytes = Array(typed.utf8)
        guard terminator != [0x0A] else { return bytes }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / 16)
        for byte in bytes {
            if byte == 0x0A { out.append(contentsOf: terminator) } else { out.append(byte) }
        }
        return out
    }
}

/// A replacement of whole lines of one side.
struct LineEdit: Sendable, Equatable {
    var side: DiffSide
    /// Lines replaced (an empty range inserts before that line).
    var lines: Range<Int>
    /// The new lines, terminators included.
    var text: [UInt8]
}

/// The result of applying a `LineEdit`: the new bytes and how many lines
/// now stand where the replaced ones were.
struct SplicedText: Sendable, Equatable {
    var bytes: [UInt8]
    var lines: Range<Int>
}

extension LineEdit {
    /// Applies the edit to `bytes`. A replacement that does not end a line
    /// gets a terminator when more lines follow it, and text appended after
    /// an unterminated last line starts on a new line, so line boundaries
    /// outside the edit never move.
    func apply(to bytes: [UInt8]) -> SplicedText {
        let starts = LineText.starts(bytes)
        let count = starts.count - 1
        let lower = min(max(lines.lowerBound, 0), count)
        let upper = min(max(lines.upperBound, lower), count)
        let from = starts[lower], to = starts[upper]
        var replacement = text
        let eol = LineText.terminator(of: bytes.isEmpty ? text : bytes)
        if !replacement.isEmpty, upper < count, !LineText.endsWithTerminator(replacement) {
            replacement += eol
        }
        var prefix = Array(bytes[..<from])
        if !replacement.isEmpty, !prefix.isEmpty, !LineText.endsWithTerminator(prefix) {
            prefix += eol
        }
        let result = prefix + replacement + Array(bytes[to...])
        return SplicedText(bytes: result, lines: lower ..< lower + LineText.lineCount(replacement))
    }
}

/// A change that a merge choice was applied to: where its lines are now on
/// each side, and what they were before the first choice. Kept so that the
/// change stays selectable (shown as resolved), takes another choice, or
/// goes back to its original text (Reset Selection).
struct MergeMarker: Sendable, Equatable {
    var a: Range<Int>
    var b: Range<Int>
    var originalA: [UInt8]
    var originalB: [UInt8]
    var choice: MergeChoice

    func lines(_ side: DiffSide) -> Range<Int> { side == .a ? a : b }

    /// After an edit of `side` that replaced `old` lines with `newCount`
    /// lines: the marker moved down or up, or nil when the edit touched its
    /// lines (it is then ordinary text).
    func shifted(side: DiffSide, replacing old: Range<Int>, with newCount: Int) -> MergeMarker? {
        let own = lines(side)
        let delta = newCount - old.count
        var copy = self
        if own.isEmpty ? own.lowerBound <= old.lowerBound && !(old.isEmpty && own.lowerBound == old.lowerBound)
                       : own.upperBound <= old.lowerBound {
            return copy
        }
        if old.upperBound <= own.lowerBound, !(old.isEmpty && own.isEmpty && old.lowerBound == own.lowerBound) {
            let moved = own.lowerBound + delta ..< own.upperBound + delta
            if side == .a { copy.a = moved } else { copy.b = moved }
            return copy
        }
        return nil
    }
}
