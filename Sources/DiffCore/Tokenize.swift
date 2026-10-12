// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin

// Line splitting, whitespace-mode line keys and the word tokenizer.

let lineFeed: UInt8 = 10
let carriageReturn: UInt8 = 13

/// Splits a buffer into lines on LF, CRLF and lone CR. Terminators stay with
/// their line. Returns the line start offsets followed by the buffer length
/// (so an empty buffer has zero lines).
func splitLines(_ buffer: UnsafeBufferPointer<UInt8>) -> [Int32] {
    let n = buffer.count
    precondition(n < Int(Int32.max), "inputs of 2 GiB or more are not supported")
    var starts = [Int32]()
    starts.reserveCapacity(n / 24 + 2)
    starts.append(0)
    guard let base = buffer.baseAddress, n > 0 else { return starts }
    if memchr(base, Int32(carriageReturn), n) == nil {
        // No CR anywhere (the common case): memchr is vectorised and several
        // times faster than a byte loop.
        let start = UnsafeRawPointer(base)
        let end = start + n
        var cursor = start
        while cursor < end, let hit = memchr(cursor, Int32(lineFeed), end - cursor) {
            cursor = UnsafeRawPointer(hit) + 1
            starts.append(Int32(cursor - start))
        }
    } else {
        var i = 0
        while i < n {
            let c = base[i]
            i += 1
            if c == lineFeed {
                starts.append(Int32(i))
            } else if c == carriageReturn {
                if i < n && base[i] == lineFeed { i += 1 }
                starts.append(Int32(i))
            }
        }
    }
    if starts[starts.count - 1] != Int32(n) { starts.append(Int32(n)) }
    return starts
}

/// Space or tab.
@inline(__always)
func isBlank(_ c: UInt8) -> Bool { c == 32 || c == 9 }

/// ASCII word characters: letters, digits and `_`.
@inline(__always)
func isWordByte(_ c: UInt8) -> Bool {
    let lower = c | 0x20
    return c == 95 || (c >= 48 && c <= 57) || (lower >= 97 && lower <= 122)
}

/// Start of the line terminator inside `[s, e)`, or `e` when there is none.
@inline(__always)
func contentEnd(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Int {
    var end = e
    if end > s && p[end - 1] == lineFeed { end -= 1 }
    if end > s && p[end - 1] == carriageReturn { end -= 1 }
    return end
}

/// The byte range of line `[s, e)` that identifies it under a whitespace
/// mode (0, 1 or 2; see `WhitespaceMode`).
@inline(__always)
func lineKey(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ ws: Int) -> (start: Int, end: Int) {
    if ws == 0 { return (s, e) }
    var start = s
    var end = contentEnd(p, s, e)
    if ws == 2 {
        while start < end && isBlank(p[start]) { start += 1 }
        while end > start && isBlank(p[end - 1]) { end -= 1 }
    }
    return (start, end)
}

/// Word tokens of one or more lines.
///
/// A token is a word, a run of blanks, a line terminator, or any other
/// single character (punctuation, symbols). Every byte of a line belongs to
/// exactly one token, except that in mode 2 leading and trailing blanks are
/// not tokenised at all, so they never match or highlight.
///
/// Words follow the default word boundaries of Unicode (UAX #29), without
/// a dictionary (see `WordBreak`): letters, digits, `_` and combining marks
/// of any script form one word, so "café" and "Ελληνικά" are words; each
/// Han ideograph and each hiragana is a word of its own, and a run of
/// katakana is one word. That is what lets a change inside a CJK line
/// highlight only the characters that changed.
///
/// This is a deterministic, locale-independent rule; it can be replaced
/// behind this type without touching the alignment code.
struct Tokens {
    /// Position of a token. Packed into one struct so that adding a token is
    /// two appends, not four.
    struct Meta {
        var start: Int32
        var end: Int32
        var line: Int32
    }

    var meta: [Meta] = []
    /// Interned token ids, contiguous so they can be handed to Myers as is.
    var ids: [Int32] = []

    var count: Int { ids.count }
    @inline(__always) func start(_ i: Int) -> Int { Int(meta[i].start) }
    @inline(__always) func end(_ i: Int) -> Int { Int(meta[i].end) }
    @inline(__always) func line(_ i: Int) -> Int32 { meta[i].line }

    mutating func removeAll() {
        meta.removeAll(keepingCapacity: true)
        ids.removeAll(keepingCapacity: true)
    }

    /// Tokens added between two polls of the cancellation token and two
    /// checks of the token limit. Counted in tokens, not lines, so one long
    /// line is interrupted as quickly as many short ones.
    static let checkInterval = 1 << 16

    /// Appends a token. Returns false when this token lands on a check point
    /// and the limit is passed or the diff was cancelled.
    @inline(__always)
    mutating func add(_ s: Int, _ e: Int, _ line: Int, _ id: Int32,
                      limit: Int, cancellation: CancellationFlag?) -> Bool {
        meta.append(Meta(start: Int32(s), end: Int32(e), line: Int32(line)))
        ids.append(id)
        if ids.count & (Tokens.checkInterval - 1) == 0 {
            return ids.count <= limit && !cancellation.isCancelled
        }
        return true
    }

    /// Appends the word tokens of the bytes `[from, to)` of buffer `p`, which
    /// lie on line `line` and hold no line terminator. Returns false, leaving
    /// the tokens incomplete, when `limit` is passed or `cancellation` is
    /// cancelled (both checked every `checkInterval` tokens).
    mutating func tokenizeRun(_ p: UnsafePointer<UInt8>, _ from: Int, _ to: Int, line: Int,
                              interner: Interner, limit: Int, cancellation: CancellationFlag?) -> Bool {
        var i = from
        while i < to {
            let j = WordBreak.tokenEnd(p, i, to)
            guard add(i, j, line, interner.intern(p + i, j - i), limit: limit, cancellation: cancellation)
            else { return false }
            i = j
        }
        return true
    }

    /// Appends the terminator token of a line whose content ends at
    /// `terminator` and which ends at `e` (nothing when they are equal).
    mutating func addTerminator(_ p: UnsafePointer<UInt8>, _ terminator: Int, _ e: Int, line: Int, ws: Int,
                                interner: Interner, limit: Int, cancellation: CancellationFlag?) -> Bool {
        guard terminator < e else { return true }
        // In modes 1 and 2 every terminator gets the same id: the empty key,
        // which no other token can have.
        let id = ws == 0 ? interner.intern(p + terminator, e - terminator) : interner.intern(p, 0)
        return add(terminator, e, line, id, limit: limit, cancellation: cancellation)
    }

    /// The content of line `[s, e)` that is tokenised: without the
    /// terminator and, in mode 2, without leading and trailing blanks.
    @inline(__always)
    static func content(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int, ws: Int)
        -> (start: Int, stop: Int, terminator: Int) {
        let terminator = contentEnd(p, s, e)
        var i = s
        var stop = terminator
        if ws == 2 {
            while i < stop && isBlank(p[i]) { i += 1 }
            while stop > i && isBlank(p[stop - 1]) { stop -= 1 }
        }
        return (i, stop, terminator)
    }

    /// Appends the tokens of line `[s, e)` of buffer `p`, which is line
    /// number `line` of its file. Returns false, leaving the tokens
    /// incomplete, when more than `limit` tokens are reached or
    /// `cancellation` is cancelled (see `tokenizeRun`).
    mutating func tokenizeLine(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int, line: Int,
                               ws: Int, interner: Interner, limit: Int = Int.max,
                               cancellation: CancellationFlag? = nil) -> Bool {
        let c = Tokens.content(p, s, e, ws: ws)
        return tokenizeRun(p, c.start, c.stop, line: line, interner: interner, limit: limit,
                           cancellation: cancellation)
            && addTerminator(p, c.terminator, e, line: line, ws: ws, interner: interner, limit: limit,
                             cancellation: cancellation)
    }
}

/// True when a token boundary certainly lies between two adjacent bytes `x`
/// and `y`. Between two ASCII bytes the rule of `Tokens` is local (only
/// runs of word bytes and runs of blanks span more than one byte). Next to
/// a non-ASCII byte the answer depends on more context, so it is
/// conservatively false: callers only use this to find *some* shared
/// boundary, never all of them.
@inline(__always)
func isTokenBoundary(_ x: UInt8, _ y: UInt8) -> Bool {
    x < 0x80 && y < 0x80 && !((isWordByte(x) && isWordByte(y)) || (isBlank(x) && isBlank(y)))
}
