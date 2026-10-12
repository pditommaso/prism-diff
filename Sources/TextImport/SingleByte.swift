// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

/// Fast decoding of the single-byte encodings the detector reports most
/// often (ISO-8859-1 and Windows-1252), without a round trip through
/// Foundation. Both are bijective on the bytes they define, so a decoded
/// text always encodes back to the same bytes.
enum SingleByte {

    /// Unicode scalar of each byte 0x80-0x9F in Windows-1252; 0 where the
    /// byte is undefined. Bytes 0xA0-0xFF are the same as ISO-8859-1.
    static let windows1252High: [UInt32] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]

    /// A 256-entry byte to scalar table, or nil for other encodings.
    static func table(for encoding: TextEncoding) -> [UInt32]? {
        switch encoding.stringEncoding {
        case .isoLatin1:
            return (0 ..< 256).map { UInt32($0) }
        case .windowsCP1252:
            return (0 ..< 256).map { $0 >= 0x80 && $0 < 0xA0 ? windows1252High[$0 - 0x80] : UInt32($0) }
        default:
            return nil
        }
    }

    /// `bytes` decoded through `table` as UTF-8, or nil when a byte is
    /// undefined (a 0 entry for a non-zero byte).
    static func decode(_ bytes: ArraySlice<UInt8>, table: [UInt32]) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / 8)
        var ok = true
        table.withUnsafeBufferPointer { map in
            bytes.withUnsafeBufferPointer { input in
                for byte in input {
                    if byte < 0x80 {
                        out.append(byte)
                        continue
                    }
                    let scalar = map[Int(byte)]
                    if scalar == 0 {
                        ok = false
                        return
                    }
                    if scalar < 0x800 {
                        out.append(UInt8(0xC0 | scalar >> 6))
                        out.append(UInt8(0x80 | scalar & 0x3F))
                    } else {
                        out.append(UInt8(0xE0 | scalar >> 12))
                        out.append(UInt8(0x80 | scalar >> 6 & 0x3F))
                        out.append(UInt8(0x80 | scalar & 0x3F))
                    }
                }
            }
        }
        return ok ? out : nil
    }
}
