// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import DiffCore

/// The default `prism diff` output: unified format with three lines of
/// context.
///
/// Hunk ranges match `diff -u`; the `---`/`+++` headers carry the paths as
/// given, without timestamps. Lines are written with their own terminators.
/// A line ended by a lone CR gets an LF after it, and an unterminated last
/// line is followed by an LF and the `\ No newline at end of file` marker.
/// Context lines are shown from A. Nothing is printed when the files compare
/// equal.
enum UnifiedRenderer {
    static let noNewlineMarker = "\\ No newline at end of file\n"

    static func write(_ result: TextDiffResult, a: [UInt8], b: [UInt8],
                      labelA: String, labelB: String, palette: Palette,
                      context: Int = 3, to out: inout ChunkedOutput) {
        guard !result.isIdentical else { return }
        let unified = UnifiedHunks(result, context: context)
        let highlights = HighlightIndex(result.blocks)

        out.append(palette.wrap("--- \(labelA)", Palette.bold) + "\n")
        out.append(palette.wrap("+++ \(labelB)", Palette.bold) + "\n")
        for hunk in unified.hunks {
            out.append(palette.wrap(hunk.header, Palette.cyan) + "\n")
            for position in hunk.lines {
                let line = unified.lines[position]
                let kind = result.blocks[line.blockIndex].kind
                switch line.kind {
                case .context:
                    writeLine(" ", line.aLine!, of: a, lines: result.linesA, color: nil,
                              highlights: [], palette: palette, to: &out)
                case .removed:
                    writeLine("-", line.aLine!, of: a, lines: result.linesA, color: palette.color(for: kind),
                              highlights: highlights.a[line.aLine!] ?? [], palette: palette, to: &out)
                case .added:
                    writeLine("+", line.bLine!, of: b, lines: result.linesB, color: palette.color(for: kind),
                              highlights: highlights.b[line.bLine!] ?? [], palette: palette, to: &out)
                }
            }
        }
    }

    private static func writeLine(_ marker: String, _ index: Int, of buffer: [UInt8], lines: LineIndex,
                                  color: String?, highlights: [Range<Int>], palette: Palette,
                                  to out: inout ChunkedOutput) {
        let line = LineBytes(buffer, lines.range(index))
        if palette.enabled && color != nil {
            var text = (color ?? "") + marker
            for piece in LineSegments(content: line.content, highlights: highlights).pieces {
                text += palette.prefix(color: color, highlighted: piece.highlighted)
                text += String(decoding: piece.bytes, as: UTF8.self)
            }
            out.append(text + Palette.reset)
        } else {
            out.append(marker)
            out.append(bytes: line.content)
        }
        if line.terminator.isEmpty {
            out.append("\n" + noNewlineMarker)
        } else {
            out.append(bytes: line.terminator)
            if line.terminator.last != 10 { out.append("\n") }
        }
    }
}
