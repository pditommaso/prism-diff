// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Darwin

/// Byte-level detectors: byte order marks, UTF-8 validity, binary
/// signatures and heuristics, and line-ending counts. All of them work on
/// raw buffers and are linear in the input.
enum Detection {

    // MARK: Byte order marks

    /// The encoding announced by a byte order mark at the start of `p`, and
    /// the mark's length. UTF-32 LE is tested before UTF-16 LE, whose mark is
    /// its prefix.
    static func byteOrderMark(_ p: UnsafeBufferPointer<UInt8>) -> (TextEncoding, Int)? {
        func starts(_ prefix: [UInt8]) -> Bool {
            p.count >= prefix.count && zip(p, prefix).allSatisfy { $0 == $1 }
        }
        if starts([0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if starts([0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if starts([0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if starts([0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if starts([0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    // MARK: UTF-8

    /// True when `p` is well-formed UTF-8: no overlong forms, no surrogates,
    /// nothing above U+10FFFF, no truncated sequence. ASCII is checked eight
    /// bytes at a time.
    static func isValidUTF8(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = p.baseAddress else { return true }
        let n = p.count
        var i = 0
        while i < n {
            // Fast path: skip ASCII a word at a time.
            if i & 7 == 0 {
                while i + 8 <= n {
                    let word = UnsafeRawPointer(base + i).loadUnaligned(as: UInt64.self)
                    if word & 0x8080_8080_8080_8080 != 0 { break }
                    i += 8
                }
                if i >= n { break }
            }
            let c = base[i]
            if c < 0x80 {
                i += 1
                continue
            }
            let length: Int
            var low: UInt8 = 0x80, high: UInt8 = 0xBF
            switch c {
            case 0xC2 ... 0xDF: length = 2
            case 0xE0: length = 3; low = 0xA0
            case 0xE1 ... 0xEC, 0xEE ... 0xEF: length = 3
            case 0xED: length = 3; high = 0x9F
            case 0xF0: length = 4; low = 0x90
            case 0xF1 ... 0xF3: length = 4
            case 0xF4: length = 4; high = 0x8F
            default: return false
            }
            guard i + length <= n else { return false }
            let second = base[i + 1]
            guard second >= low && second <= high else { return false }
            var k = 2
            while k < length {
                guard base[i + k] & 0xC0 == 0x80 else { return false }
                k += 1
            }
            i += length
        }
        return true
    }

    // MARK: Binary detection

    /// Leading bytes of formats that are never text, at their offsets.
    /// Only signatures specific enough not to start a real text file are
    /// listed; other binary formats are caught by `profile`. PDF and RTF are
    /// documents, not binary (see `documentSignature`), and binary property
    /// lists are converted to XML text (`isBinaryPropertyList`).
    static let binarySignatures: [(offset: Int, bytes: [UInt8])] = [
        (0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),          // PNG
        (0, [0xFF, 0xD8, 0xFF]),                                        // JPEG
        (0, Array("GIF87a".utf8)), (0, Array("GIF89a".utf8)),           // GIF
        (0, [0x49, 0x49, 0x2A, 0x00]), (0, [0x4D, 0x4D, 0x00, 0x2A]),   // TIFF
        (0, [0xCF, 0xFA, 0xED, 0xFE]), (0, [0xCE, 0xFA, 0xED, 0xFE]),   // Mach-O, little-endian
        (0, [0xFE, 0xED, 0xFA, 0xCF]), (0, [0xFE, 0xED, 0xFA, 0xCE]),   // Mach-O, big-endian
        (0, [0xCA, 0xFE, 0xBA, 0xBE]), (0, [0xCA, 0xFE, 0xBA, 0xBF]),   // universal binary, Java class
        (0, [0x7F, 0x45, 0x4C, 0x46]),                                  // ELF
        (0, [0x50, 0x4B, 0x03, 0x04]), (0, [0x50, 0x4B, 0x05, 0x06]),   // zip (also docx, odt, jar)
        (0, [0x1F, 0x8B, 0x08]),                                        // gzip
        (0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),                      // xz
        (0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]),                      // 7z
        (0, [0x28, 0xB5, 0x2F, 0xFD]),                                  // zstd
        (257, Array("ustar".utf8)),                                     // tar
        (0, Array("SQLite format 3".utf8) + [0]),                       // SQLite
        (0, [0x00, 0x61, 0x73, 0x6D]),                                  // WebAssembly
    ]

    /// True when `p` starts with one of `binarySignatures`.
    static func hasBinarySignature(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
        binarySignatures.contains { signature in
            let end = signature.offset + signature.bytes.count
            guard p.count >= end else { return false }
            return signature.bytes.indices.allSatisfy { p[signature.offset + $0] == signature.bytes[$0] }
        }
    }

    /// The document format announced by the first bytes, if any.
    static func documentSignature(_ p: UnsafeBufferPointer<UInt8>) -> DocumentFormat? {
        func starts(_ prefix: String) -> Bool {
            let bytes = Array(prefix.utf8)
            return p.count >= bytes.count && zip(p, bytes).allSatisfy { $0 == $1 }
        }
        if starts("%PDF-") { return .pdf }
        if starts("{\\rtf") { return .rtf }
        return nil
    }

    /// True when `p` starts like a binary property list.
    static func isBinaryPropertyList(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
        let magic = Array("bplist0".utf8)
        return p.count >= 8 && zip(p, magic).allSatisfy { $0 == $1 }
    }

    /// What a sample of the content looks like.
    struct ContentProfile: Equatable {
        /// The sample holds a NUL byte.
        var hasNUL = false
        /// Share of control bytes other than tab, LF, VT, FF, CR, backspace
        /// and escape (which plain-text logs use).
        var controlRatio = 0.0
        /// The sample looks like BOM-less UTF-16 in a Latin script: a NUL in
        /// most units, all at one parity.
        var utf16: TextEncoding?
        /// The sample has NULs, all at one parity: possibly UTF-16 with few
        /// NULs (CJK text), in the byte order this names.
        var nulParity: TextEncoding?

        /// Too many control bytes, or NULs that UTF-16 does not explain.
        var looksBinary: Bool {
            utf16 == nil && (hasNUL || controlRatio > Detection.maximumControlRatio)
        }
    }

    /// Bytes examined by `profile`.
    static let sampleSize = 64 << 10
    /// Above this share of control bytes, a sample looks binary.
    static let maximumControlRatio = 0.10

    /// Profiles the first `sampleSize` bytes of `p`.
    static func profile(_ p: UnsafeBufferPointer<UInt8>) -> ContentProfile {
        var profile = ContentProfile()
        let n = min(p.count, sampleSize)
        guard n > 0 else { return profile }
        var control = 0, evenZeros = 0, oddZeros = 0
        for i in 0 ..< n {
            let c = p[i]
            if c >= 0x20 { continue }
            if c == 0 {
                if i & 1 == 0 { evenZeros += 1 } else { oddZeros += 1 }
            }
            switch c {
            case 8, 9, 10, 11, 12, 13, 27: break
            default: control += 1
            }
        }
        profile.hasNUL = evenZeros + oddZeros > 0
        profile.controlRatio = Double(control) / Double(n)
        // UTF-16 text in a Latin script has a NUL in nearly every unit, on
        // the high-byte side. Parity is judged on the sample alone, so a
        // truncated file (odd length) is still recognised.
        let units = n / 2
        if oddZeros > 0 && evenZeros == 0 { profile.nulParity = .utf16LittleEndian }
        if evenZeros > 0 && oddZeros == 0 { profile.nulParity = .utf16BigEndian }
        if units >= 1 {
            if oddZeros * 10 >= units * 3 && evenZeros * 50 <= units {
                profile.utf16 = .utf16LittleEndian
            } else if evenZeros * 10 >= units * 3 && oddZeros * 50 <= units {
                profile.utf16 = .utf16BigEndian
            }
        }
        return profile
    }

    // MARK: Line endings

    /// Counts the LF, CR LF and lone CR terminators of UTF-8 (or any ASCII
    /// compatible) text.
    static func lineEndings(_ p: UnsafeBufferPointer<UInt8>) -> LineEndings {
        var result = LineEndings()
        guard let base = p.baseAddress, p.count > 0 else { return result }
        let n = p.count
        let last = base[n - 1]
        result.hasFinalNewline = last == 10 || last == 13
        if memchr(base, 13, n) == nil {
            // No CR anywhere: count LFs with the vectorised memchr.
            let start = UnsafeRawPointer(base)
            let end = start + n
            var cursor = start
            while cursor < end, let hit = memchr(cursor, 10, end - cursor) {
                result.lf += 1
                cursor = UnsafeRawPointer(hit) + 1
            }
            return result
        }
        var i = 0
        while i < n {
            let c = base[i]
            if c == 10 {
                result.lf += 1
            } else if c == 13 {
                if i + 1 < n && base[i + 1] == 10 {
                    result.crlf += 1
                    i += 1
                } else {
                    result.cr += 1
                }
            }
            i += 1
        }
        return result
    }

    // MARK: Lenient Unicode decoding

    /// `body` decoded as UTF-8, UTF-16 or UTF-32 (`encoding`), with every
    /// ill-formed sequence, lone surrogate or stray trailing byte replaced by
    /// U+FFFD. `clean` is false when anything was replaced; a clean decode
    /// always encodes back to the same bytes.
    static func decodeUnicode(_ body: ArraySlice<UInt8>, _ encoding: TextEncoding) -> (utf8: [UInt8], clean: Bool) {
        let replacement: [UInt8] = [0xEF, 0xBF, 0xBD]  // U+FFFD
        switch encoding.stringEncoding {
        case .utf8:
            if body.withUnsafeBufferPointer({ isValidUTF8($0) }) { return (Array(body), true) }
            return (Array(String(decoding: body, as: UTF8.self).utf8), false)
        case .utf16LittleEndian, .utf16BigEndian:
            let little = encoding.stringEncoding == .utf16LittleEndian
            let units = body.withUnsafeBytes { raw in
                (0 ..< raw.count / 2).map { i -> UInt16 in
                    let v = raw.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)
                    return little ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
                }
            }
            var out = [UInt8]()
            out.reserveCapacity(body.count + body.count / 2)
            let error = transcode(units.makeIterator(), from: UTF16.self, to: UTF8.self, stoppingOnError: false) {
                out.append($0)
            }
            let stray = body.count % 2 != 0
            if stray { out += replacement }
            return (out, !error && !stray)
        default:  // UTF-32
            let little = encoding.stringEncoding == .utf32LittleEndian
            let units = body.withUnsafeBytes { raw in
                (0 ..< raw.count / 4).map { i -> UInt32 in
                    let v = raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self)
                    return little ? UInt32(littleEndian: v) : UInt32(bigEndian: v)
                }
            }
            var out = [UInt8]()
            out.reserveCapacity(body.count)
            let error = transcode(units.makeIterator(), from: UTF32.self, to: UTF8.self, stoppingOnError: false) {
                out.append($0)
            }
            let stray = body.count % 4 != 0
            if stray { out += replacement }
            return (out, !error && !stray)
        }
    }

    /// True when `body` reads well as UTF-32: whole units, every one a
    /// scalar, none in the unassigned planes 3-13. A UTF-16 LE text whose
    /// first character is U+0000 starts with the same four bytes as the
    /// UTF-32 LE byte order mark; this tells them apart.
    static func isPlausibleUTF32(_ body: ArraySlice<UInt8>, littleEndian: Bool) -> Bool {
        guard body.count % 4 == 0 else { return false }
        return body.withUnsafeBytes { raw in
            for i in 0 ..< raw.count / 4 {
                let v = raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self)
                let value = littleEndian ? UInt32(littleEndian: v) : UInt32(bigEndian: v)
                if Unicode.Scalar(value) == nil || (0x30000 ..< 0xE0000).contains(value) { return false }
            }
            return true
        }
    }

    /// True when decoded UTF-8 text reads like text in some script: among
    /// its first `sampleSize` bytes at most 2% of the characters are
    /// controls (other than tab, LF, VT, FF, CR), unassigned, private-use
    /// or U+FFFD. Random bytes read as UTF-16 fail this: about a tenth of
    /// the code units are private-use or surrogates.
    static func looksLikeText(_ utf8: [UInt8]) -> Bool {
        let sample = utf8.prefix(sampleSize)
        var bad = 0, scalars = 0
        for scalar in String(decoding: sample, as: UTF8.self).unicodeScalars {
            scalars += 1
            switch scalar.value {
            case 9 ... 13: continue
            case 0xFFFD: bad += 1; continue
            default: break
            }
            switch scalar.properties.generalCategory {
            case .control, .unassigned, .privateUse, .surrogate: bad += 1
            default: break
            }
        }
        return scalars > 0 && bad * 50 <= scalars
    }
}
