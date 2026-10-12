// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

/// Word boundaries for the word tokenizer, after the default rules of
/// Unicode Standard Annex #29 without a dictionary, in pure Swift over
/// UTF-8 bytes (no Foundation, no locale).
///
/// Classes of a character:
/// - letter: ASCII letters, digits and `_`, and every other alphabetic or
///   decimal-digit character that is not one of the next two classes
///   (Latin, Greek, Cyrillic, Hangul, Arabic, ...);
/// - katakana: joins only other katakana (and the prolonged sound mark);
/// - ideographic: Han ideographs and hiragana; each one is its own word;
/// - extend: combining marks, format characters (ZWJ, ZWNJ), variation
///   selectors and emoji modifiers; they stay with the character before
///   them (a ZWJ also pulls in the emoji that follows it);
/// - blank: space and tab, grouped into runs;
/// - other: punctuation, symbols, other spaces, emoji, and bytes that are
///   not valid UTF-8; each one is its own token.
///
/// ASCII stays on a byte fast path; Unicode properties are looked up only
/// for non-ASCII characters.
enum WordBreak {

    enum Class {
        case letter, katakana, ideographic, extend, blank, other
    }

    /// End of the token that starts at byte `i` of `p`, before `end`.
    @inline(__always)
    static func tokenEnd(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
        let c = p[i]
        if c < 0x80 {
            if isWordByte(c) { return scan(p, i + 1, end, .letter) }
            if isBlank(c) {
                var j = i + 1
                while j < end && isBlank(p[j]) { j += 1 }
                return j
            }
            return extend(p, i + 1, end)
        }
        guard let (scalar, length) = decode(p, i, end) else { return i + 1 }
        let kind = classify(scalar)
        switch kind {
        case .letter, .katakana: return scan(p, i + length, end, kind)
        default: return extend(p, i + length, end, joinsEmoji: scalar.properties.isEmoji)
        }
    }

    /// Extends a word of class `kind` (letter or katakana) from `j`.
    private static func scan(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ kind: Class) -> Int {
        var j = start
        while j < end {
            let c = p[j]
            if c < 0x80 {
                guard kind == .letter && isWordByte(c) else { return j }
                j += 1
                continue
            }
            guard let (scalar, length) = decode(p, j, end) else { return j }
            let next = classify(scalar)
            guard next == kind || next == .extend else { return j }
            j += length
        }
        return j
    }

    /// Appends the extend characters that follow position `j`. After a ZWJ,
    /// an emoji joins the token too when the token started with one.
    private static func extend(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int,
                               joinsEmoji: Bool = false) -> Int {
        var j = start
        var afterJoiner = false
        while j < end && p[j] >= 0x80 {
            guard let (scalar, length) = decode(p, j, end) else { return j }
            if classify(scalar) == .extend {
                afterJoiner = scalar.value == 0x200D
            } else if afterJoiner && joinsEmoji && scalar.properties.isEmoji {
                afterJoiner = false
            } else {
                return j
            }
            j += length
        }
        return j
    }

    /// The scalar of the well-formed UTF-8 sequence at `i`, and its length;
    /// nil for an invalid or truncated sequence.
    @inline(__always)
    static func decode(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> (Unicode.Scalar, Int)? {
        let c = UInt32(p[i])
        let length: Int
        var value: UInt32
        var low: UInt8 = 0x80, high: UInt8 = 0xBF
        switch c {
        case 0xC2 ... 0xDF: length = 2; value = c & 0x1F
        case 0xE0: length = 3; value = c & 0x0F; low = 0xA0
        case 0xE1 ... 0xEC, 0xEE ... 0xEF: length = 3; value = c & 0x0F
        case 0xED: length = 3; value = c & 0x0F; high = 0x9F
        case 0xF0: length = 4; value = c & 0x07; low = 0x90
        case 0xF1 ... 0xF3: length = 4; value = c & 0x07
        case 0xF4: length = 4; value = c & 0x07; high = 0x8F
        default: return nil
        }
        guard i + length <= end else { return nil }
        let second = p[i + 1]
        guard second >= low && second <= high else { return nil }
        value = value << 6 | UInt32(second & 0x3F)
        var k = 2
        while k < length {
            let b = p[i + k]
            guard b & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(b & 0x3F)
            k += 1
        }
        guard let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, length)
    }

    /// The class of a non-ASCII scalar.
    static func classify(_ scalar: Unicode.Scalar) -> Class {
        let v = scalar.value
        // Katakana, the prolonged sound mark, halfwidth katakana, the
        // katakana phonetic extensions.
        if (0x30A0 ... 0x30FF).contains(v) && v != 0x30FB || (0x31F0 ... 0x31FF).contains(v)
            || (0xFF66 ... 0xFF9F).contains(v) {
            return .katakana
        }
        // Hiragana (iteration marks included), but not the combining voiced
        // sound marks U+3099 and U+309A, which are extend.
        if (0x3040 ... 0x309F).contains(v) && v != 0x3099 && v != 0x309A { return .ideographic }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return .extend
        case .modifierSymbol where (0x1F3FB ... 0x1F3FF).contains(v):
            return .extend
        case .decimalNumber:
            return .letter
        default:
            break
        }
        if properties.isIdeographic { return .ideographic }
        if properties.isAlphabetic { return .letter }
        return .other
    }
}
