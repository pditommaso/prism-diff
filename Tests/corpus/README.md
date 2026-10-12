# Test corpus

Shared inputs and expected outputs for Prism's tests. Everything here is
synthetic: the files were written for this project or are produced by the
generator in `scripts/`. Nothing comes from another product.

On macOS `tests/corpus` and `Tests/corpus` name the same directory; git tracks
it as `Tests/corpus`.

## Layout

| Path | Contents |
| --- | --- |
| `fixtures/` | Committed inputs. Byte-exact; never reformat them (see `.gitattributes`). |
| `fixtures.sha256` | sha256 of every file under `fixtures/`, relative to this directory. |
| `golden/` | Expected outputs compared by `Golden.check` in `PrismTestSupport`. |
| `merge/<case>/` | Three-way merge cases: `base.txt`, `a.txt`, `b.txt`, optional `args.txt` and the golden `expected.json`. |
| `merge.sha256` | sha256 of every file under `merge/`, relative to this directory. |
| `encodings/` | Text-import inputs: encodings, line endings, binary files and documents, with `expected.tsv`. |
| `encodings.sha256` | sha256 of every file under `encodings/`, relative to this directory. |
| `scripts/make-encodings.py` | Writes `encodings/`. |
| `generated/` | Large inputs rebuilt by `scripts/generate.py`. Git-ignored. |
| `generated.sha256` | sha256 of every file the generator writes. |
| `scripts/make-repo.sh` | Rebuilds the git fixture repository from `fixtures/repo-src/`. |
| `scripts/generate.py` | Writes the large synthetic inputs into `generated/`. |

## Provenance

All origins are Prism's own synthetic fixtures or generator output. The
hand-written fixtures were first written for this project's research
prototypes (diff engine and folder scan) and seeded from there unchanged,
apart from the differences listed below. None of them comes from another
product, its documentation or its screenshots, and none is a copy of the
private research notes, screenshots or behaviour specifications
(`PRISM_DIRTY_ROOT=<workspace> scripts/ci/check-cleanroom.sh` verifies the
last point byte for byte).

| File | Origin | Purpose | Used from |
| --- | --- | --- | --- |
| `fixtures/text/a.swift`, `b.swift` | Hand-written synthetic Swift pair | Small text diff with line and word changes; the 8-change golden | M1, M3, M4 |
| `fixtures/text/big_a.txt`, `big_b.txt` | Synthetic text, 100,000 and 100,099 lines (about 5.3 MB each) | Large-file performance and rendering budgets | M1, M3, M4 |
| `fixtures/text/slider_a.groovy`, `slider_b.groovy` | Hand-written synthetic Groovy pair | Placement of an ambiguous ("sliding") insertion | M1 |
| `fixtures/folders/left/`, `right/` | Hand-written synthetic trees | Folder comparison: same, changed, left-only and right-only entries | M8, M9 |
| `fixtures/repo-src/1-init/` … `4-worktree/` | Hand-written snapshots of a tiny history | Input for `make-repo.sh` | M5, M7 |
| `generated/diff20k_{a,b}.txt` | `generate.py` | 20,000 lines each with no line in common | M1 |
| `generated/m1_{a,b}.txt` | `generate.py` | 1,000,000 lines with 10 scattered edits | M1, M11 |
| `generated/min_{a,b}.json` | `generate.py` | About 5 MB of single-line minified JSON with 20 in-line edits | M1, M4 |
| `generated/crlf_{a,b}.txt` | `generate.py` from `big_a.txt` | LF against CRLF, same text | M1, M2 |
| `generated/crlf100k_{a,b}.txt` | `generate.py` from `big_a.txt` | CRLF against LF, 100k lines | M1, M2 |
| `generated/ind_{a,b}.txt` | `generate.py` from `big_a.txt` | Indentation and trailing-space changes only | M1, M4 |
| `golden/harness-selftest.txt` | Written by hand | Self-test of the golden harness | M0 |
| `golden/diff-a-b.json` | `prism diff Tests/corpus/fixtures/text/a.swift Tests/corpus/fixtures/text/b.swift --json` | The 8-change JSON golden | M1 |
| `golden/diff-reference-a-b.json` | `prism diff --json` of the original study pair (same `a.swift`; `b.swift` names another product on line 20, so the word hunk there ends at B column 35, not 28). The pair itself is not committed; `scripts/accept/M01.sh` runs it when `PRISM_REFERENCE_FIXTURES` or `PRISM_DIRTY_ROOT` points at it | M1 |
| `golden/diff-a-b.unified.txt` | The same with `--unified`, run from the repository root (the headers hold the relative paths) | Unified output | M1 |
| `golden/diff-a-b.side-by-side.txt` | The same with `--side-by-side --width 160` (160 is also the default without `$COLUMNS`) | Side-by-side output | M1 |
| `golden/diff-slider.json` | `prism diff` of `slider_a.groovy` and `slider_b.groovy` with `--json` | One insert at B `[10,17)` | M1 |
| `merge/a-only/` | Hand-written planting plan; only A edits a line | Automatic choice of A | M1, M6 |
| `merge/b-only/` | Same plan; only B edits a line and appends one | Automatic choice of B, insertion at the end | M1, M6 |
| `merge/disjoint/` | Hand-written 20-step release checklist; A and B edit far apart | Both edits taken automatically | M1, M6 |
| `merge/same-edit/` | Hand-written server config; A and B make the same two edits | No A-B difference, no conflict | M1, M6 |
| `merge/overlap-conflict/` | Same config; A and B change the same line differently | One conflict | M1, M6 |
| `merge/insert-same-point/` | Hand-written weekend to-do list; A and B insert different lines at one spot | One conflict | M1, M6 |
| `merge/delete-vs-edit/` | Hand-written rota; A deletes the line B edits | One conflict | M1, M6 |
| `merge/notes/` | `notes.txt` of `fixtures/repo-src/1-init` (base), `2-mainchg` (A) and `3-feat` (B) | The mergetool case: one conflict | M1, M6, M7 |
| `merge/crlf/` | Hand-written verse; A in CRLF with one edit, B in LF with another; `args.txt` holds `--ws 1` | Line endings ignored: both edits taken | M1, M6 |
| `merge/mixed/` | Hand-written pantry list without final newlines; autos on both sides plus a conflict on the last line | Several regions, unterminated last lines | M1, M6 |
| `merge/adjacent-change-insert/` | Hand-written walk plan; A edits a line, B inserts a line right after it | A change next to an insert: two automatic regions, no conflict | M1, M6 |
| `merge/append-after-closing-line/` | Hand-written Swift-like snippet; A edits the first line, B appends a function after the closing `}` | Edits far apart in base although the A-B diff pairs the `}` lines differently: two automatic regions, no conflict | M1, M6 |
| `merge/split-by-agreement/` | Hand-written soup recipe; A edits lines 2-3, B lines 3-4, both make the same edit to line 3 | Overlapping edits split where A and B agree: two automatic regions, no conflict | M7 |

| `encodings/*.txt`, `image-png.bin`, `archive.zip`, `macho.bin`, `random.bin`, `doc.rtf`, `doc.pdf` | `make-encodings.py` (synthetic text in each encoding; a 2x2 PNG; a zip with a fixed timestamp; a bare arm64 Mach-O header; a byte pattern; hand-written RTF and PDF) | Encoding, BOM, line-ending and binary classification, round trips, document text | M2, M3, M6 |
| `encodings/doc.docx`, `doc.odt`, `doc.doc` | `make-encodings.py --documents` (macOS `textutil` from `doc.rtf`) | Word and OpenDocument conversion | M2 |
| `encodings/*.expected`, `expected.tsv` | `make-encodings.py` | The text each document must give; the classification `prism sniff` must report | M2 |

The `generated/` set covers both prototype case sets, the flat one and the
cross-language one: the latter differs only by adding `crlf100k_{a,b}.txt`.

### Deliberate differences from the original study pair

`fixtures/text/b.swift` line 20 and `fixtures/folders/right/src/main.swift`
use the string `"Prism"` where the pair studied during research used another
product's name. The change count, change positions and line numbers are
unchanged (the changed line is still one replaced token), but the character
extent of that token's in-line highlight is shorter. Expected in-line ranges
for that line are therefore Prism's own golden values, not the research
notes'.
`golden/diff-reference-a-b.json` pins the output on the original pair too,
and `scripts/accept/M01.sh` checks it whenever that pair is available
outside the repository.

The Swift files under `fixtures/` are diff inputs, not Prism sources, so they
carry no SPDX header: a header would shift every line number the milestone
acceptance criteria refer to. This is a deliberate deviation from "every
`*.swift` file has an SPDX header". `scripts/ci/check-spdx.sh` exempts only
files whose path and sha256 are pinned in `fixtures.sha256`; any new or edited
Swift file under `fixtures/` must carry a header until it is reviewed and
added to the manifest (see `scripts/tests/spdx-selftest.sh`).

## The git fixture repository

A nested `.git` directory cannot be committed, so the history is replayed:

```sh
Tests/corpus/scripts/make-repo.sh /path/to/empty-or-new-dir
```

The result has three commits (`init` and `mainchg` on `master`, `feat` on
`feature`, forked from `init`), `master` checked out, and uncommitted edits to
`conf.ini` and `main.swift`. Author, committer and dates are fixed, so the
commit hashes are always `3a9becc`, `fefde12` and `5dff3f6`. The script turns
off global and system git configuration and never touches `~/.gitconfig`.

## Regenerating

```sh
/usr/bin/python3 -I Tests/corpus/scripts/generate.py            # write generated/
/usr/bin/python3 -I Tests/corpus/scripts/generate.py --check    # write, then verify generated.sha256
/usr/bin/python3 -I Tests/corpus/scripts/generate.py --write-manifest   # after changing a case on purpose
```

The generator uses a fixed seed (`random.Random(1)`), so its output is
byte-identical from run to run. Verify the committed fixtures with:

```sh
cd Tests/corpus && shasum -a 256 -c fixtures.sha256
```

## Merge cases

Each directory under `merge/` is one three-way merge: `base.txt`, `a.txt` and
`b.txt` are the inputs, and `expected.json` is the canonical JSON of the
result (`Merge3Result.json`, which `prism merge3 --json` prints). If
`args.txt` exists, it holds the extra `prism merge3` flags for the case (only
`--ws <mode>` today). The inputs are `.txt` files so they need no SPDX
exemption. `Merge3Tests` merges every case and compares it with
`expected.json`; `PRISM_UPDATE_GOLDEN=1` rewrites the goldens. After changing
a case on purpose, refresh the manifest:

```sh
cd Tests/corpus && find merge -type f ! -name .DS_Store | sort | xargs shasum -a 256 > merge.sha256
shasum -a 256 -c merge.sha256
```

## Text-import corpus

`encodings/` holds one small file per case: UTF-8 with and without a BOM,
UTF-16 LE and BE with a BOM, UTF-16 LE without one, ISO-8859-1,
Windows-1252, Shift JIS (CRLF), CRLF and mixed line endings, a file without
a final newline, an empty file, four binary files and five documents.
`expected.tsv` lists the kind, encoding (or document format), BOM and
line-ending style each must be classified as; `TextImportTests` and
`scripts/accept/M02.sh` both read it. Text files must also round-trip:
decoded and encoded again they give back the same bytes.

```sh
/usr/bin/python3 -I Tests/corpus/scripts/make-encodings.py
cd Tests/corpus && find encodings -type f ! -name .DS_Store | sort | xargs shasum -a 256 > encodings.sha256
```

## Golden files

Tests compare their output with `golden/<name>` through
`Golden.check(_:against:)`. To accept new output, run the tests with
`PRISM_UPDATE_GOLDEN=1`, review the diff of `golden/` and commit it.
