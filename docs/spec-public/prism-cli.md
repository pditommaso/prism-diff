# The `prism` command-line tool

`prism` has two uses, chosen by its first argument:

- **Engine commands.** `prism diff`, `prism merge3` and `prism sniff` are
  the headless front end of Prism's comparison engine. They need no window
  server and are meant for terminals, scripts and tests. `help`, `-h`,
  `--help` and `--version` (and no argument at all) also belong here.
- **Opening files in the app.** Any other first argument (a path, or an
  option such as `--partial-changeset`, `--merge`, `--wait`, `-w`,
  `--UUID` or `--short-version`) sends the files to the Prism app; see
  [Opening files in the app](#opening-files-in-the-app). This mode accepts
  the same options and exit codes as `ksdiff`.

A file literally named `diff`, `merge3`, `sniff` or `help` must be written
with a path when it comes first, for example `prism ./diff ./other`.
`prism --help` describes both uses.

The tool may be installed under another name (`prism-diff` when another
program named `prism` is present); engine messages use the name it was
started as.

## Grammar

```
prism [--help | --version]
prism diff   [--ws 0|1|2] [--json | --unified | --side-by-side] [--color] [--width N] A B
prism merge3 [--ws 0|1|2] [--json] BASE A B
prism sniff  [--json] FILE ...
```

Options of a command may appear before, between or after its file operands.
`--` ends the options, so a file whose name starts with `-` can follow it.
Options that take a value accept it as the next argument (`--ws 1`) or after
an equals sign (`--ws=1`). Every command answers `-h` or `--help` with its own
help text.

### Files

Every input is decoded before it is compared (`prism sniff` shows the
result for any file):

1. `/dev/null` and empty files are empty text.
2. RTF, RTFD, DOC, DOCX, WordML and ODT documents (recognised by their
   extension, or for RTF by content) are converted to plain text with the
   macOS text system, and PDF files (by extension or content) with PDFKit.
   Extracted text ends with a newline. When only the content looked like
   RTF or PDF (a `.txt` file starting with `%PDF-`, say) and the conversion
   fails, the file is read as text. Binary property lists are shown as
   their XML form.
3. A byte order mark selects UTF-8, UTF-16 or UTF-32 (either byte order),
   and such a file is always text: ill-formed units (a lone surrogate, a
   stray last byte) are shown as U+FFFD and the file is reported as not
   round-tripping. `FF FE 00 00` is UTF-32 LE only when the rest reads as
   UTF-32, otherwise UTF-16 LE starting with U+0000.
4. Binary files are refused (`prism diff` and `prism merge3` exit 2 with
   `<path>: binary file; only text files can be compared`). A file is binary
   when it starts with a known binary signature (PNG, JPEG, GIF, TIFF,
   Mach-O, ELF, zip, gzip, xz, 7z, zstd, tar, SQLite, WebAssembly), or when
   its first 64 KiB hold a NUL byte or more than 10% control characters.
   In the second case it is text after all when its NULs all sit at one
   byte parity and it decodes cleanly as UTF-16 into characters that read
   as text (BOM-less CJK UTF-16, say); or when it is at most 50 MiB, its
   extension does not name an image, audio, video, archive, executable,
   font or disk-image type, and it is valid UTF-8 or, without any NUL, in
   an encoding Foundation's detector finds.
5. BOM-less UTF-16 is recognised by its pattern of NUL bytes in the first
   64 KiB (a truncated file with an odd length included).
6. Valid UTF-8 is read as UTF-8.
7. Otherwise the encoding is guessed by Foundation from the first MiB
   (Windows-1252 and Shift JIS are suggested, the language of the current
   locale is the hint); Windows-1252 text that uses none of the bytes
   0x80-0x9F is reported as ISO-8859-1. Windows-1252, then ISO-8859-1, are
   the fallbacks.

The decoded text is compared and shown as UTF-8; byte and UTF-16 columns
in the output refer to that UTF-8 text. Line endings are never changed. A
byte order mark or an encoding alone is therefore never a difference: the
same text in UTF-8 and in UTF-16 compares equal.

Any readable file works, including named pipes and process substitution
(`<(command)`). A lone `-` reads standard input; it may name only one of
the inputs. A missing or unreadable path, a directory, a file of 2 GiB or
more (or whose UTF-8 text reaches 2 GiB), or a document whose text cannot
be extracted is an error, reported with its reason.

Lines end with LF, CRLF or a lone CR; the terminator belongs to its line.

### Whitespace modes (`--ws`)

| Mode | Effect |
| --- | --- |
| `0` (default) | Every byte counts, the line terminator included. |
| `1` | LF, CRLF and CR are treated as the same terminator. |
| `2` | As `1`, and spaces and tabs at the start and end of each line are ignored. |

The mode only decides what matches. Output always shows the decoded text
unchanged, and every range points into it. A difference only in the final
newline (one file ends with a line terminator, the other does not) is
shown at every mode, as a change of the last line.

## Exit status

The commands follow the convention of diff(1):

| Status | `prism diff` | `prism merge3` | `prism sniff` |
| --- | --- | --- | --- |
| 0 | The files compare equal (under the whitespace mode). | Every difference merged automatically. | Every file was classified. |
| 1 | The files differ. | At least one conflict remains. | Not used. |
| 2 | Usage error, binary or unreadable input, or standard output could not be written. | Same. | Usage error, unreadable or oversized file, failed document conversion, failed write. |

`prism --help` and `prism --version` exit 0; any other top-level usage error
of the engine commands exits 2 (app-integration mode has its own statuses,
below). When standard output fails (for example it is closed), the tool
prints one line on standard error and exits 2. A broken pipe (the reader
went away, as with `| head`) is handled as in diff(1) and cat(1): with the
default `SIGPIPE` disposition the tool is ended by that signal (status 141
in most shells); when the caller ignores `SIGPIPE`, the write fails and the
tool exits 2 with one line on standard error.

## `prism diff`

### Unified output (default, `--unified`)

The unified format of `diff -u` with three lines of context:

- a `--- A` and a `+++ B` header, with the paths exactly as given and no
  timestamps;
- `@@ -start,count +start,count @@` hunk headers whose numbers are those
  `diff -u` prints for the same set of differences (a count of 1 is
  omitted; an empty side starts at the line before the change, 0 at the
  top of the file);
- lines prefixed with a space (context, shown from A), `-` (only in A) or
  `+` (only in B), each with its own terminator;
- after a line that has no terminator, `\ No newline at end of file`.

Within each run of adjacent differences every `-` line comes before every
`+` line, as `diff -u` writes them, so the output applies with patch(1)
and `git apply` when both inputs are UTF-8 (without a byte order mark) and
end their lines with LF or CRLF. Other inputs are not reproduced byte for
byte, and the patch does not apply to them: text decoded from another
encoding (or with a byte order mark) is written as UTF-8, and lone-CR line
endings get an added LF.

A line ended by a lone CR is followed by an LF so the output stays one line
per row. When the files compare equal nothing is printed.

Where the engine places an ambiguous insertion differently from GNU diff,
the hunk positions follow Prism's placement; the counts of lines and hunks
are unaffected.

### Side-by-side output (`--side-by-side`)

One row per line pair:

```
<A number> <A text> <marker> <B number> <B text>
```

- Each half (number, space, text) is `(width - 3) / 2` cells wide. The width
  is `--width N` (from 20 to 4096), else `$COLUMNS` when it is a usable number,
  else 160.
- Numbers are 1-based and right-aligned to the widest line number.
- The marker is a space for equal lines, `<` for a line only in A, `>` for a
  line only in B and `|` for a changed pair.
- Tabs expand to the next multiple of 8. Other control characters show as
  `?`. East Asian wide characters count two cells; combining marks none.
- Text that does not fit is cut and ends with `…`.
- Trailing blanks of a row are not written.

Every line of both files is shown, also when they compare equal.

### Colour (`--color`)

`--color` always turns ANSI escapes on; there is no automatic detection, and
without the flag no escape sequence is written. Inserted lines are green,
deleted lines red and changed lines yellow; inside changed lines the
differing words are shown in reverse video. In unified output the file
headers are bold and the hunk headers cyan. `--color` has no effect on
`--json`, and `--width` none outside the side-by-side view.

### JSON output (`--json`)

A single document, written with a fixed key order, one block per line, and
LF line endings. It contains no file names, so the same two inputs give the
same bytes on every machine.

```json
{"format":"prism-diff","version":1,"whitespace":0,"changes":2,"blocks":[
{"kind":"equal","a":[0,3],"b":[0,3]},
{"kind":"change","a":[3,4],"b":[3,4],"words":[{"aLine":3,"bLine":3,"a":[4,9],"b":[4,11],"aUTF16":[4,9],"bUTF16":[4,11]}]},
{"kind":"insert","a":[4,4],"b":[4,6]},
{"kind":"equal","a":[4,10],"b":[6,12]}
]}
```

Top-level keys, in this order:

| Key | Value |
| --- | --- |
| `format` | Always `"prism-diff"`. |
| `version` | Schema version, `1`. A reader should reject versions it does not know. |
| `whitespace` | The `--ws` mode used, 0, 1 or 2. |
| `changes` | Number of blocks whose kind is not `equal`. |
| `blocks` | Every block, in order. |

The blocks cover both files completely and in order. Each block has:

| Key | Value |
| --- | --- |
| `kind` | `equal`, `insert` (lines only in B), `delete` (lines only in A) or `change` (paired lines that differ). |
| `a`, `b` | Line ranges `[start, end)`: 0-based, end excluded. An insert has an empty A range at the insertion point, a delete an empty B range. A change always has as many A lines as B lines. |
| `words` | Only on `change` blocks: the differing parts of each line pair, in line order. |

Each entry of `words` has:

| Key | Value |
| --- | --- |
| `aLine`, `bLine` | 0-based line numbers of the pair. |
| `a`, `b` | Byte columns `[start, end)` relative to the start of the line. An empty range is an insertion point on that side. |
| `aUTF16`, `bUTF16` | The same columns counted in UTF-16 code units of the decoded line, as text views on macOS count them. |

Very large changed regions (more than 500,000 word tokens, or more than
32,000,000 bytes) may be reported without `words` detail, as a `delete`
followed by an `insert`. A region of one line against one line is refined
up to 8,000,000 tokens, counted between the common prefix and suffix of
the two lines, so a long line with a local edit keeps its detail however
long it is.

## `prism merge3`

Merges A and B, two edited versions of BASE. Where only one side changed a
region relative to BASE, that side is taken; where both changed it in
different ways, the region is a conflict. The merged text contains the
automatic choices and leaves unresolved conflicts out.

Regions are found in BASE coordinates, from the BASE-A and BASE-B diffs.
Edits of A and B that overlap in BASE are decided together: they share a
BASE line, two replaced ranges touch, or both sides insert at the same
point (or one inserts inside lines the other replaced). Such a group is
automatic when only one side has edits in it, equal when both made the same
edit, and a conflict otherwise. An insertion right before or after lines
the other side replaced is decided on its own, so A editing a line and B
inserting a line right after it are two automatic regions, not a conflict.
An insertion or deletion that could sit in several places among equal lines
(a blank line added to a run of blank lines, say) is placed as far down as
it goes on both sides, so the same edit made by A and by B is not taken
twice. The A-B diff is not used to decide anything.

Inputs whose A and B together reach 2 GiB are refused (exit status 2): the
merged text could hold all of both.

Without `--json` a short summary is printed: one line per region where A
and B differ, then the totals.

### JSON output (`--json`)

```json
{
  "format": "prism-merge3",
  "version": 1,
  "whitespace": 0,
  "conflicts": 1,
  "unresolved": 1,
  "regions": [
    {"kind": "equal", "choice": "none", "a": [0, 1], "b": [0, 1], "base": [0, 1], "merged": [0, 1]},
    {"kind": "conflict", "choice": "none", "a": [1, 2], "b": [1, 2], "base": [1, 2], "merged": [1, 1]},
    {"kind": "equal", "choice": "none", "a": [2, 3], "b": [2, 3], "base": [2, 3], "merged": [1, 2]}
  ],
  "merged": "line1\nline3\n"
}
```

| Key | Value |
| --- | --- |
| `format` | Always `"prism-merge3"`. |
| `version` | Schema version, `1`. |
| `whitespace` | The `--ws` mode used. |
| `conflicts` | Regions where both sides changed. |
| `unresolved` | Conflicts without a choice; from the command line always equal to `conflicts`. |
| `regions` | Every region, in order; together they cover A, B and the merged text. |
| `merged` | The merged text as one string when it is valid UTF-8. Otherwise an array with one entry per merged line (terminator included): a string for a valid line, an array of byte values for one that is not. |

Each region has:

| Key | Value |
| --- | --- |
| `kind` | `equal` (A and B agree), `auto` (one side changed and was taken) or `conflict`. |
| `choice` | What the merged text takes: `none`, `a`, `b`, `aThenB` or `bThenA`. Equal regions and unresolved conflicts have `none`; equal regions contribute A's lines. |
| `a`, `b` | The region's line ranges in A and B. |
| `base` | The BASE lines that both the A range and the B range replace (an empty range is an insertion point). |
| `merged` | The region's line range in the merged text. |

All ranges are 0-based `[start, end)` line ranges. Strings escape `"`, `\`
and control characters; other characters are written as they are.

## `prism sniff`

Reports how each file would be read for comparison, one record per file in
the order given, records separated by a blank line:

```
file: notes-utf16.txt
kind: text
encoding: utf-16le
bom: yes
line-endings: crlf
lines: 12
final-newline: yes
bytes: 846
round-trip: yes
```

| Key | Value |
| --- | --- |
| `file` | The path as given. |
| `kind` | `text`, `document` (text extracted from a rich-text or PDF file), `binary`, `directory` or `missing` (nothing at the path). |
| `format` | Documents only: `rtf`, `rtfd`, `doc`, `docx`, `wordml`, `odt`, `pdf` or `bplist` (a binary property list, shown as XML). |
| `encoding` | Text only: the lower-case IANA name, such as `utf-8`, `utf-16le`, `utf-16be`, `utf-32le`, `iso-8859-1`, `windows-1252` or `shift_jis`. |
| `bom` | Text only: whether the file starts with a byte order mark. |
| `line-endings` | Text and documents: `lf`, `crlf`, `cr`, `mixed` or `none`. |
| `lines` | Text and documents: the number of lines, an unterminated last line included. |
| `final-newline` | Text and documents: whether the last line ends with a terminator. |
| `bytes` | Size of the file (not for `directory` and `missing`). |
| `round-trip` | Text only: whether encoding the decoded text again in the same encoding, with the same BOM, gives back the file byte for byte. Exact for UTF-8, UTF-16, UTF-32, ISO-8859-1 and Windows-1252; checked on the first MiB for other encodings. |

With `--json` each record is one JSON object on its own line, with the same
keys in the same order; numbers are numbers and `yes`/`no` are `true` and
`false`:

```json
{"file":"image-png.bin","kind":"binary","bytes":74}
```

Binary, missing and directory are classifications, not errors: the exit
status is 0 when every file was classified. An unreadable or oversized
file, or a document whose text cannot be extracted, is reported on
standard error, the remaining files are still reported, and the status
is 2.

## Opening files in the app

`prism FILE ...` and the options below open files and folders in the Prism
app. Version-control tools run it as their external diff program: every
pair of files that one `git difftool` run sends lands in one window, a
*changeset*, with a sidebar listing the files. It accepts the same options
and exit codes as `ksdiff`, so existing git, Mercurial and Subversion setups
work once the command name is changed to `prism`. Prism installs no `ksdiff`
command.

### Grammar

```
prism --short-version
prism --supports-capability NAME
prism [OPTIONS] [--diff] FILE [FILE ...]
prism [OPTIONS] --partial-changeset [--UUID ID] [--relative-path PATH] FILE FILE
prism [OPTIONS] --changeset (--filelist [--relative-path PATH] [--file-status S] FILE FILE)...
prism --mark-changeset-as-closed ID
prism [OPTIONS] --merge --output OUT [--base BASE] FILE FILE

OPTIONS:          -w | --wait | --no-wait, --label LABEL
after a FILE:     --snapshot | --no-snapshot
```

- `--name=value` is the same as `--name value`, up to `--`.
- After `--` every argument is a file, except `--snapshot` and
  `--no-snapshot`, which still apply to the file before them (common
  merge-tool command lines put them there). Before `--` they may also
  follow `--base BASE`.
- `--wait`, `-w` and `--no-wait` exclude each other; so do `--snapshot` and
  `--no-snapshot` for one file. A merge always waits (`--no-wait` is a
  usage error with `--merge`); every other command returns at once unless
  `--wait` is given.
- `--short-version` as the first argument prints `VERSION (BUILD)` whatever
  follows it. `--help` and `--version` as the first argument run the engine
  forms above.
- A first argument `diff`, `merge3`, `sniff` or `help` selects an engine
  command: write such a file as `./diff`.
- `--supports-capability` prints `YES` for `diffs-v1`, `changesets-v1`,
  `partial-changesets-v1` and `merges-v1`, and `NO` otherwise.

#### Commands

- **diff** (the default): the files open in a new comparison. They must
  exist.
- **partial changeset**: one pair joins the changeset of its caller. Pairs
  share a changeset when they come from the same version-control process
  (the nearest `git`, `hg`, `svn`, `p4` or `bzr` ancestor of `prism`,
  identified by its PID and start time) or carry the same `--UUID`. A
  missing file is shown as an absent side (`/dev/null`), and the pair's
  status is *added* when the left side is absent, *removed* when the right
  side is, *changed* otherwise, unless `--file-status` says so. The sidebar
  row is `--relative-path`, or else the right file's path relative to the
  working directory.
- **changeset**: a whole changeset in one call. Each `--filelist` starts a
  pair. Two folders expand into one pair per file found on either side,
  sorted by relative path.
- **merge**: a three-way merge of the two files (A, then B) with `--base`
  as their common ancestor, saved to `--output`. The two files and the base
  must exist, and so must the output's folder; a missing output file is
  created only when the result is saved. Only plain text files can be
  merged (not RTF, Word, OpenDocument, PDF or property-list documents).
  Without a base every difference is a conflict; the lines both files share
  stay common. The window is named after the output
  file. `prism` waits for the window to close and exits 0 only if the
  result was saved with every conflict resolved and not changed since;
  any other way of closing it (including Don't Resolve) gives 1.
- **mark changeset as closed**: no more pairs will join the changeset with
  that `--UUID`; later ones start a new changeset. A changeset named by a
  UUID also stops accepting pairs after 10 seconds without one.

A changeset fed by a process stops accepting pairs when that process
exits. If the user closes a changeset window while pairs are still
arriving, the next pair opens a new window.

The window title is the `--label`; otherwise, for a changeset, the
caller's arguments without the tool and its diff subcommand, as
“HEAD~1” in repo, or `Changes in repo` when none remain (`repo` is the last
component of the working directory).

#### Temporary files

Files that their owner may delete as soon as `prism` returns are copied
by the app before `prism` exits. A file is temporary when `--snapshot`
follows it, or, without `--snapshot` or `--no-snapshot`, when its path:

1. starts with `/tmp/`, `/private/tmp/`, `/var/`, `/private/var/`, the
   caller's `$TMPDIR` or the system temporary folder; or
2. contains `-Tmp-`, `.svn/tmp/` or `.svn/text-base/`; or
3. has a folder named `NAME.` followed by 12 lowercase hex digits
   (Mercurial's extdiff copies).

A copied file shows only its file name, since its folder means nothing to
the user.

#### Native argument forms

When Subversion runs `prism` as `diff-cmd` (`-u -L LABEL -L LABEL LEFT
RIGHT`), the pair joins the svn changeset and the label's path is the
sidebar row. When Perforce runs it as `P4DIFF` (`LEFT RIGHT`), the pair
joins the p4 changeset.

### Talking to the app

`prism` connects to the app over a Unix-domain socket at
`~/Library/Application Support/Prism/prism.sock`. The socket file has mode
0600, and the app answers only peers of the same user (checked with the
peer's credentials). One request and one reply travel on each connection as
JSON messages, each preceded by its length (4 bytes, big-endian). A request
that waits keeps its connection; the app sends one more message when the
document closes.

If nothing answers on the socket, `prism` starts the app in the
background and waits up to 20 seconds for it to listen. An app started
this way shows no window of its own besides the comparison.

While waiting, `prism` notices the app quitting both from the connection
closing and from a process-exit watch on the app.

### Environment

| Variable | Effect |
|---|---|
| `PRISM_SOCKET_PATH` | Socket path, for `prism` and the app alike (tests point it at a temporary folder; at most 103 bytes). |
| `PRISM_APP_PATH` | App bundle `prism` starts when the app is not running. Default: the bundle `prism` lives in (symbolic links resolved), otherwise the app registered under `io.github.pditommaso.prism`. |
| `PRISM_LAUNCHED_BY_CLI` | Set by `prism` when it starts the app; not for users. |
| `PRISM_TESTING` | `1` in tests: the app never brings itself to the front, and a release build honours `PRISM_INTEGRATION_ROOT` (Integration window installs into that folder and its `gitconfig`). |

When `prism` starts the app it passes on only `PRISM_SOCKET_PATH`,
`PRISM_TESTING`, `PRISM_PERF_LOG` and `PRISM_INTEGRATION_ROOT`.

### Exit status

| Status | Meaning |
|---|---|
| 0 | The app has the files; with `--wait`, the window or tab was closed; for `--merge`, the merge was saved resolved. Also for the informational options. |
| 1 | A usage error, a request the app refused, a launch failure, the app quitting during `--wait`, or a merge closed without being resolved. |
| 255 | Communication with a running app failed. |

### git

The Integration window writes, with `git config --global`:

```
[difftool "prism"]
	cmd = prism --partial-changeset --relative-path "$MERGED" -- "$LOCAL" "$REMOTE"
[mergetool "prism"]
	cmd = prism --merge --output "$MERGED" --base "$BASE" -- "$LOCAL" --snapshot "$REMOTE" --snapshot
	trustExitCode = true
```

and, when Prism is made the default tool, `diff.tool = prism`,
`difftool.prompt = false`, `merge.tool = prism` and `mergetool.prompt =
false`. Before the first change the config file is saved
as it is (or noted as absent). Removing the integration writes it back
exactly, comments and all, if nobody edited it since; otherwise every
`difftool.prism.*` and `mergetool.prism.*` key is removed and the
default-tool keys get their earlier values back if they still hold Prism's.
Then `git difftool` (or `git difftool -t prism`) opens all changed files in
one changeset window, and `git mergetool` (or `git mergetool -t prism`)
opens each conflicted file in a merge window; because the exit status is
trusted, git marks the file resolved only when the merge was saved
resolved, and otherwise reports that the merge failed and keeps the
conflict.
