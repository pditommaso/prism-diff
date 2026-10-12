# DiffCore

The text diff engine: two-way line and word diffs, whitespace modes, and
three-way merge. Pure Swift, importing only `Darwin` and `Dispatch` (never
Foundation), built with plain
`-O` (no unsafe flags, no `-Ounchecked`).

| File | Role |
| --- | --- |
| `Model.swift` | Public types: `DiffOptions`, `DiffBlock`, `WordHunk`, `TextDiffResult`, ... |
| `TextDiff.swift` | Pipeline: short-circuits, interning, unique anchors, discard, gap Myers, block walk, parallel refine |
| `Refine.swift` | Word refinement, whitespace-equal pre-pairing, line pairing, per-pair hunks |
| `Myers.swift` | Linear-space Myers bisection with an explicit stack and a cost cap |
| `Interner.swift` | Byte string to dense `Int32` id table |
| `Tokenize.swift` | Line splitting, whitespace-mode line keys, word tokenizer |
| `WordBreak.swift` | Unicode word boundaries (UAX #29 without a dictionary) for the tokenizer |
| `LineRange.swift` | Half-open line range value type |
| `Cancellation.swift` | `CancellationFlag`, `DiffError`, the async wrapper |
| `UTF16Columns.swift` | UTF-8 byte offsets to UTF-16 offsets for AppKit |
| `Unified.swift` | Unified line sequence and `diff -u` hunks |
| `Merge3.swift` | Three-way merge: regions, automatic choices, conflicts, `applying(choice:to:)` |
| `Merge3JSON.swift` | Canonical JSON of a merge (`prism merge3 --json`, merge goldens) |

## Hot-loop rules

Measured on large inputs; each of these cost 20-50 % when ignored.

1. Never append to an array stored in a class property inside a loop: every
   append pays an exclusivity check and a uniqueness check. `swap` the array
   into a local for the duration of the loop (see `Myers.diff`).
2. Keep per-element data in one struct array rather than parallel arrays
   (`Tokens.Meta`): fewer appends, fewer bounds checks.
3. Hand token ids to Myers as `UnsafePointer<Int32>` into a contiguous
   `[Int32]`; never index a Swift array inside the snake loop.
4. Reuse scratch state per worker (`Myers`, `Interner.reset()`, token
   buffers) instead of allocating per line pair.
5. Keep bookkeeping out of the diagonal loop; do it once when it is needed
   (the cost-cap fallback scans V only when the cap is hit).
6. Size buffers by what the algorithm can touch (V by the cost limit, not by
   N).
7. Do not dispatch tiny workloads: refinement runs inline below 8 jobs or
   64 KiB.
8. Poll the cancellation token at coarse checkpoints only (per bisection,
   every 4096 diagonals, before a long prefix/suffix strip, per refine job
   and line pair, every 64k tokens and interned lines), never per element. An inner loop that sees the token stops early and leaves
   valid but meaningless state; the pipeline's checks between stages turn
   that into `DiffError.cancelled`.
