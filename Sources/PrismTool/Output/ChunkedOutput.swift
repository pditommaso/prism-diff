// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import PrismProtocol

/// Collects rendered text and hands it to a `TextSink` in chunks of about
/// `chunkBytes`, so a million-line diff is neither one giant string nor a
/// million tiny writes.
struct ChunkedOutput {
    /// Flush threshold, in UTF-8 bytes.
    static let chunkBytes = 64 << 10

    private let sink: TextSink
    private var buffer = ""

    init(_ sink: TextSink) {
        self.sink = sink
        buffer.reserveCapacity(Self.chunkBytes + 4096)
    }

    /// Appends `text`, flushing when the buffer is full.
    mutating func append(_ text: String) {
        buffer += text
        if buffer.utf8.count >= Self.chunkBytes { flush() }
    }

    /// Appends raw input bytes, shown as UTF-8 (ill-formed bytes appear as
    /// U+FFFD). Callers pass whole lines or token-aligned pieces, so a
    /// multi-byte sequence is never split between two calls.
    mutating func append(bytes: ArraySlice<UInt8>) {
        append(String(decoding: bytes, as: UTF8.self))
    }

    /// Writes whatever is buffered.
    mutating func flush() {
        guard !buffer.isEmpty else { return }
        sink.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
