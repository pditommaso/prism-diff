// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Foundation

/// Text for the folder table cells.
public enum FolderFormat {
    /// Decimal units without decimals: "512 bytes", "12 KB", "3 MB", "2 GB".
    public static func size(_ bytes: UInt64) -> String {
        switch bytes {
        case ..<1000: return bytes == 1 ? "1 byte" : "\(bytes) bytes"
        case ..<1_000_000: return "\(rounded(bytes, 1000)) KB"
        case ..<1_000_000_000: return "\(rounded(bytes, 1_000_000)) MB"
        default: return "\(rounded(bytes, 1_000_000_000)) GB"
        }
    }

    private static func rounded(_ value: UInt64, _ unit: UInt64) -> UInt64 {
        (value + unit / 2) / unit
    }

    /// Medium date and medium time in the user's locale, for example
    /// "11 Oct 2026 at 14:46:29".
    public static func date(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, locale: locale, timeZone: timeZone))
    }
}
