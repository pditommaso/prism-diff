# Changelog

All notable changes to Prism are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/). Releases are tagged
`vX.Y.Z` and published on GitHub Releases by `scripts/release.sh` (see
CONTRIBUTING.md, "Releasing"); the milestone builds before 1.0.0 were tagged
`mNN`.

## [Unreleased]

## [1.1.0] - 2026-10-21

### Added

- The changeset sidebar is resizable: drag its right edge, double-click
  it to return to the default width.
- The divider between the A and B panes can be dragged in the Blocks and
  Fluid layouts (the whole Fluid gutter is the grip); the path bar
  follows it, each pane keeps a minimum width, and a double-click splits
  the panes evenly again.
- New windows open with the sidebar width and pane split last dragged.
- Folder groups in the changeset sidebar collapse and expand with a
  click, shown by a chevron and a folder icon. The file being compared
  stays open while its folder is collapsed, and Next File / Previous File
  open collapsed folders as they reach them.

### Fixed

- Folder comparison with "compare contents": files whose dates differ
  could stay marked as pending while the Mac was busy with other work
  (another folder scan, for example), because their checks got no
  processor time until the load stopped. They now run alongside it.
- Folder comparison with "compare contents": each checked file no
  longer re-sorts its whole folder. With thousands of touched files (a
  fresh checkout, for example) the checks used to take minutes of CPU;
  they now finish in about the time it takes to read the files.

### Unverified on screen

- The 50 ms cancellation bound for a 300k-line diff (unit test) is now
  checked on a developer Mac only, like the other timing-sensitive tests:
  the shared 3-CPU CI runners miss it under load (118 ms).
- The deep pass of the 200k-file folder tree gets a 16 s budget on CI
  (scale 8), up from 6 s: the current macos-26 runner image takes 8.6 to
  13.3 s for it with this release and with 1.0.0 alike. On a developer
  Mac it stays under 1 s, within the 2 s budget.
- On CI, the M1 acceptance run checks that every diff stops when
  cancelled, but no longer the 50 ms bound; that bound is checked on a
  developer Mac.
- Resizing and collapsing were checked by hand on a developer build;
  VoiceOver on the new folder rows and on the resize handles was not.
- The release candidate itself: Prism.app from the zip is verified
  (signature, versions) but not launched.

## [1.0.0] - 2026-10-12

<!-- scripts/release.sh turns this section into the release notes. The
detailed record of this version is under "Milestone notes for 1.0.0"
below. -->

Prism 1.0: the first release of the app. A native macOS (14 or later,
Apple silicon) comparison tool for text files and folders, with one
command-line tool, `prism`: it opens comparisons in the app for git,
editors and scripts (ksdiff-compatible options), and runs the headless
`diff`, `sniff` and `merge3` subcommands.

### Highlights

- Text comparison in Blocks, Fluid and Unified layouts, with word-level
  highlights, Ignore Whitespace, Wrap Lines, find, text size and four
  built-in themes (light or dark, multicolor or single color). Encodings,
  byte order marks, UTF-16 and RTF, PDF and office documents are imported
  as text.
- Editing in place with live re-diff, copying changes between sides, and
  saving in the file's own encoding.
- Three-way merge (`prism --merge`, `git mergetool -t prism`): choose
  left, right or both per conflict, edit the result, and exit 0 only for a
  saved, fully resolved merge.
- `git difftool -t prism` opens one window per run listing every changed
  file; `prism --wait` blocks until the comparison closes.
- Folder comparison with live refresh, filters, drill-down tabs, and
  staged copies between the two sides with a summary before copying.
- Tabs, the file shelf, a launch window, full menus and window
  restoration (Quit and Keep Windows).
- The Integration window installs the `prism` command and the git
  difftool and mergetool settings, and removes them again.

### Added in milestone m11 (release hardening)

- Performance regression suite, `scripts/perf/run.sh`, run in CI (job
  `perf`) with `PRISM_PERF_SCALE=3`. Every budget is a test: the M1
  engine cases, the M5 warm `prism` app-integration round trip (median <= 1 ms), the M8
  200k-file folder scan and live refresh, and the M3/M4 first screen
  (read, diff and model build, layout and an offscreen draw: the
  100k-line pair within 500 ms in Blocks, Unified and wrapped, and a 5 MB
  single line within 3 s). Locally, at scale 1, the first screen of the
  100k-line pair takes 60-80 ms.
- `Prism --bench-first-screen [options] A B`, the headless mode behind the
  first-screen tests: no window, no Dock icon, no run loop. `Prism
  --version` prints the version line shown in About.
- Diagnostics through unified logging (`os.Logger`): subsystem
  `io.github.pditommaso.prism`, categories `diff`, `import`, `folder`,
  `ipc`, `merge` and `ui`. Paths and user text are logged as private.
  The `PRISM_PERF_LOG` test hooks are unchanged. There is no crash or
  usage reporting.
- Clean-room audit, `scripts/ci/cleanroom-audit.sh`, run by the `guards`
  CI job: every string literal and every run of words in the repository
  is compared against SHA-256 hashes of distinctive strings of the
  original app (the list holds hashes only), and, with
  `PRISM_REFERENCE_SCREENS`, every file against the reference screenshots
  by hash. It reports 0 matches. Five strings it found were reworded:
  Settings > Text "Turn on Wrap Lines for new comparisons", Settings >
  Folders "Show hidden files", the Integration window's "Example:"
  captions, a find bar comment and a bench help line.
- Release flow. The `VERSION` file is the single source of the version:
  a SwiftPM build-tool plugin (`Plugins/VersionPlugin`) compiles it into
  `PrismInfo.version`, with the build number from `PRISM_BUILD_NUMBER`
  (default 1; the CI run number for releases). `scripts/release.sh
  [--dry-run]` does the whole release: preflight (tools, clean tree,
  SemVer, a dated CHANGELOG section, a new tag), a clean strict build and
  all tests, the clean-room guards, the headless acceptance scripts,
  Prism.app ad-hoc signed with the hardened runtime and checked with
  `codesign --verify --deep --strict` and for its version strings, then
  `dist/Prism-<version>-macos-arm64.zip`, SHA256SUMS and
  release notes from this section, with file times set to the commit
  time. Without `--dry-run` it tags `v<version>`, pushes the tag and
  publishes the GitHub release. CI runs it for a push to master whose
  commit message contains `[release]`, after all checks pass.

### Changed

- Version 1.0.0 (`CFBundleShortVersionString`); `CFBundleVersion` is the
  build number of the release run.
- Distribution (decision D7): a zipped, ad-hoc-signed Prism.app on GitHub
  Releases. It is not notarized: clear the quarantine flag once with
  `xattr -dr com.apple.quarantine /Applications/Prism.app`. There is no
  DMG, Homebrew cask or in-app updater; new versions come from GitHub
  Releases.

### Known gaps

- Not notarized (see above); Gatekeeper refuses the app until the
  quarantine flag is cleared.
- In merge windows, long lines are clipped (no horizontal scrolling or
  wrapping), and Find, Swap A & B and the file shelf are not available.
  Images and folders cannot be merged.
- Installing `prism` into `/usr/local/bin` needs write access there; Prism
  never asks for administrator rights and suggests `~/bin` instead.
- Changesets from `git difftool` are not saved with the window state.
- File > Save stays disabled while nothing is unsaved, and there are no
  registration or update-check menu items (intended).

### Unverified on screen

No GUI test runs remain before this release. Everything below is covered
by unit tests and headless runs only; the owner checks it on the release
candidate.

- The AppKit app unit tests (and three timing-sensitive tests) run on a
  developer Mac, not on the CI runners, which have no usable display; the
  release build on CI is gated on every other test and check.
- The release candidate itself: Prism.app from the zip has been verified
  (signature, versions) but not launched.
- First paint and scrolling frame rates: the perf suite measures the first
  screen offscreen; missed-frame budgets during scrolling and live resize
  have no headless check.
- Text (M03/M04): the selected-band colours and the jump to change 473
  with the layout pinned to Blocks.
- Editing (M06): copying every change through the menus.
- Merge (M07): the merge window itself (layouts were compared only as
  offscreen renders).
- Folders (M08/M09): the folder window, filters, drill-down tabs, staging
  and the copy sheet; the 200k-file "first rows <= 50 ms" check once
  failed under load (62.6 ms) and passed on rerun.
- Shell (M10): the launch window, the file shelf, the menus through
  accessibility, tab modes after View-menu presses, Quit and Keep Windows
  through its alternate menu item and the relaunch that restores three
  tabs, and Move Tab to New Window.
- The reworded settings labels ("Turn on Wrap Lines for new comparisons",
  "Show hidden files") and the Integration window's "Example:" captions.

## Milestone notes for 1.0.0 (m02 to m11)

The detailed record of the milestones that make up 1.0.0, kept as written
during development.

### Changed: one `prism` command (owner decision, 2026-10-12)

- The app-integration CLI is no longer a separate program: it is folded
  into `prism`. `prism diff|merge3|sniff`, `help`, `-h`, `--help` and
  `--version` (or no argument) run the headless engine tools as before;
  any other first argument (paths, or options such as
  `--partial-changeset`, `--merge`, `--wait`, `--UUID`, `--snapshot`)
  opens the files in the app, with the same options and exit codes (0, 1,
  255) as ksdiff. A file named `diff`, `merge3`, `sniff` or `help` is
  written `./diff` when it comes first. `prism --help` describes both uses.
  The former CLI target is now the `PrismClient` library linked into
  `prism`. No `ksdiff` binary or alias is shipped.
- The bundle ships one helper, `Prism.app/Contents/Helpers/prism`.
- The socket is `~/Library/Application Support/Prism/prism.sock`.
- The Integration window installs one link, `prism`. When another
  program named `prism` is in the destination or on the PATH, it is left
  alone and Prism offers `prism-diff` as the link name instead. The
  replace / keep both / restore handling of a foreign tool is gone.
- git: `difftool.prism.cmd = prism --partial-changeset --relative-path
  "$MERGED" -- "$LOCAL" "$REMOTE"` and `mergetool.prism.cmd = prism
  --merge --output "$MERGED" --base "$BASE" -- "$LOCAL" --snapshot
  "$REMOTE" --snapshot`; removal still restores the config byte for byte.
- docs/spec-public/prism-cli.md now covers both uses (the separate CLI
  page is gone).
- Unverified on screen (no GUI runs remain): the Integration window's
  "Install as prism-diff" sheet, and starting the app from the bundled
  `Helpers/prism`. Unit tests cover the installer and the dispatch rule.

### Milestone m11a: accessibility, Help and documentation

- VoiceOver: every interactive element of the launch, text, folder,
  changeset and three-way merge scopes (and of the Integration, Settings,
  About and Help windows) has a name. Path-bar components read their
  folder name (no longer the folder icon's description), the chevrons
  between them and tab icons are hidden, the merge arrows read "Copy to the
  right" / "Copy to the left" / "More ways to merge", the find bar's steps
  "Previous Match" / "Next Match", the layout, merge, find-scope and
  background controls have group names, a tab's badge reads "N files",
  folder lists read "Folder A" / "Folder B" / "Copy directions" and each
  gutter button "Copy direction for <name>". The merge view exposes its
  visible lines ("Result line 4, conflict" and the text).
- Keyboard: the launch window's drop area takes the focus and opens the
  file chooser on Return, Enter or Space; selecting a text tab focuses its
  text pane; document, merge and Help windows recalculate their key view
  loop (top to bottom: tab strip, find bar, text, bottom bar).
- Increase Contrast: stronger difference bands, word highlights, borders,
  line numbers and rules (text themes), stronger conflict colours, folder
  row and arrow colours and find-match outlines; open windows follow a
  change of the setting at once.
- Reduce Motion: windows open and close without animation. Prism animates
  nothing of its own (scrolling to a change, match or conflict is
  immediate); a unit test keeps animation APIs out of the app sources.
- Help > Prism Help opens a Help window with our own topics: opening a
  comparison, reading a text comparison, editing, three-way merge,
  folders, tabs and the shelf, the `prism` command, git setup,
  accessibility, and every keyboard shortcut (read from the main menu).
  Help > Getting Started opens it on the first topic.
- About and Help carry the non-affiliation notice, word for word as in the
  README. check-cleanroom.sh allows the product name on lines that carry
  that notice only.
- README rewritten for v1.0: install from the release zip (ad-hoc signed:
  right-click > Open, or `xattr -dr com.apple.quarantine`), linking
  `prism`, git difftool/mergetool setup, building with the Command Line
  Tools, licence.
- `scripts/accept/a11y-audit.sh`: headless audit (offscreen windows, AX
  hierarchy walk, contrast/motion, Help, README checks). It never launches
  the app.
- docs/spec-public checked: only our own behavioural docs (no identifiers
  or prose from the private specs; the only shared phrases are the git
  command lines and the temporary-path patterns, which are interface facts).

### Known gaps (m11a)

- Unverified on screen (no GUI run was allowed; everything above is
  covered by headless unit tests only):
  - what VoiceOver actually speaks, and its navigation order;
  - the focus ring of the launch drop area and Tab order with Keyboard
    Navigation on;
  - the look of the Increase Contrast colours (light and dark), and the
    live switch when the setting changes;
  - window animations under Reduce Motion;
  - the Help window's layout, text styling and search field;
  - the About window with the longer notice.
- The Integration window's "Install in:" pop-up is still unnamed; the label
  goes in after the CLI/installer rework is merged.
- The README has placeholder text instead of screenshots.

### Milestone m07: three-way merge and git mergetool

- `prism --merge --output OUT [--base BASE] [--] A B` opens a three-way
  merge. It always waits (`--no-wait` is refused with `--merge`), never
  creates the output itself (the app does when the result is first saved;
  the output's folder must exist), and exits 0
  only when the result was saved with every conflict resolved and left
  unchanged since; any other close (Don't Resolve, Don't Save, quitting)
  exits 1, so git can trust it. `--snapshot` may also follow `--base BASE`.
  `--supports-capability merges-v1` answers YES.
- The Integration window's git setup also writes `mergetool.prism.cmd`
  (`prism --merge --output "$MERGED" --base "$BASE" -- "$LOCAL" --snapshot
  "$REMOTE" --snapshot`) and `mergetool.prism.trustExitCode = true`, plus
  `merge.tool = prism` and `mergetool.prompt = false` for the default tool.
  Removal restores the global config byte for byte, or removes both prism
  sections key by key after an outside edit.
- Merge window: named after the output file; a header with A's and B's
  names and a red count of unresolved conflicts that turns into "Resolved
  Document"; Blocks and Fluid show A | result | B (Fluid with connectors in
  the two gutters), Unified the interleaved A/B lines next to the result,
  and a first merge opens in Unified (remembered apart from two-way
  windows). Conflicts are yellow, with darker word and line-number cells;
  an unresolved conflict shows one empty placeholder line in the result.
  The bottom bar reads "Conflict N of M" with a warning or check mark.
- Merge menu in a merge window: Choose Left (⌘→), Choose Right (⌘←), Reset
  Selection (⌥⌘⌫), Choose Both (Left First) (⌥⌘→), Choose Both (Right
  First) (⌥⌘←); View > Previous/Next Conflict (⌥⌘↑/⌥⌘↓). Choices undo and
  redo; a double click in the result column edits that region's text,
  which also resolves a conflict. File > Save writes the result in A's
  encoding.
- Closing with unresolved conflicts asks Review Conflicts (default, selects
  the first one) or Don't Resolve; closing resolved but unsaved asks to
  save. Quitting with an unresolved merge asks first.
- Three-way engine (CARRYOVER for M7): a chunk both sides edited is split
  where A and B agree on a line standing for the same base line, and each
  piece is decided on its own by content, so neighbouring edits that agree
  in between are taken automatically instead of making one big conflict
  (new corpus case `split-by-agreement`). The merged text now starts as A
  with every automatic choice applied: an unresolved conflict keeps A's
  lines (the window shows the placeholder); resetting an automatic region
  still takes nothing. Merge goldens updated accordingly.
- Only plain text is merged: RTF, Word, OpenDocument, PDF and
  property-list documents are refused with a message, and the merge ends
  unresolved, so a document is never replaced by its converted text. A
  merge always compares exactly, whatever the Ignore Whitespace
  preference, so no whitespace-only edit is dropped. Saving text that was
  read lossily (e.g. UTF-16 with a lone surrogate) asks first. Opening the
  editor over a conflict and leaving it unchanged never resolves it, and
  empty text over a placeholder is no edit. Quitting reports each open
  merge (resolved if it was saved resolved) to its prism before the
  socket closes. Without a base each difference is its own conflict and the
  lines both files share stay common (also where both sides inserted at
  one point).
- The stub server resolves merges headlessly (`--merge-choice`), for
  `git mergetool` tests without the app. `scripts/accept/M07.sh`.

### Known gaps (m07)

- Long lines are clipped at their column's edge in the merge window (no
  horizontal scrolling or wrapping there yet), and the editor works on one
  region at a time.
- Find, Swap A & B and the file shelf are not available in merge windows.
- Image merges and merges of folders are not supported.

### Fixed after the final GUI batch (integration branch)

- A layout chosen from the View menu is recorded for its tab right away
  (`windowTabs` perf event), so each tab's Blocks/Fluid/Unified is visible
  per tab; the menu reaches the selected tab's comparison (unit-tested).
- Quit and Keep Windows writes the state file when chosen as well as at
  termination, before the socket server stops; a cancelled quit removes
  it. The write path is unit-tested (three tabs and their layouts come
  back).
- The selection probe (`selectedGutterPoint`) is measured in the window a
  tab really lives in, not in the comparison's own hidden window.
- Under PRISM_TESTING=1 the app keeps its preferences in a separate suite
  (`io.github.pditommaso.prism.testing`), so acceptance runs no longer
  rewrite the owner's layout, recent files or merge layout (an earlier GUI
  run had left the owner's `prism.text.viewMode` at Unified, which made
  M03's Blocks checks probe a Unified window). M03 now launches in Blocks
  explicitly.
- M06 no longer counts one re-diff per Copy to Right: copying a change
  that is already copied re-diffs nothing; the saved file decides.

### Unverified on screen (no GUI runs remain)

- M10: the tab modes recorded after View-menu presses, Quit and Keep
  Windows through the accessibility press of the alternate menu item, and
  the relaunch that restores three tabs (the controller paths are
  unit-tested; whether AX pressing a hidden alternate item sends its own
  action is not).
- M10: Move Tab to New Window through the tab's accessibility action
  (unit-tested; on screen it failed only because the relaunch had not
  restored the tabs).
- M03: the selected-band colour probes and the jump to change 473 with
  the layout pinned to Blocks (unit-tested in a tab: both panes at the same
  offset, no horizontal offset, alignment error 0).
- M06: copying every change through the menus with the relaxed re-diff
  wait.
- M07: the merge window on screen (layouts were compared only as
  offscreen renders).
- M08: "200k: first rows <= 50 ms" is a timing check that also failed
  once before M10 under load (62.6 ms, then passed on rerun); no M10 work
  was found before the first rows, so it is left as is.

### Integration of m07 and m10

- Merge windows stay windows of their own next to M10's tabbed document
  windows: the frontmost-document lookup, background menu validation and
  menu routing recognise them, the Merge menu is renamed for them, View >
  Previous/Next Conflict act on them, and Quit and Keep Windows never
  restores them (like changesets, they belong to a git run). Quitting
  reports each open merge to its prism before the socket closes.

### Added (milestone m10: tabs, file shelf, launch window, menus, state restoration)

- Document windows hold any number of comparisons as tabs, whatever they
  compare: text, folders (drill-down levels), a changeset, or nothing yet.
  Equal-width tabs with a scope icon, the "a | b" title, a file-count badge
  (click: show or hide the file shelf) and a close button on hover; "+"
  adds a tab; tabs that do not fit go into an overflow menu; a context
  menu offers New Tab, Close Tab, Close Other Tabs, Move Tab to New Window
  and Open Files in New Tab. Drag a tab along the strip to reorder it, or
  away from it to move it into a new window. Window > Select Next Tab /
  Select Previous Tab (Shift-Command-] / [).
- File > New Window (Command-N), New Tab (Command-T), New from Clipboard
  (Shift-Command-N), Open Recent ("a | b" entries, Clear Menu), Close
  Comparison (Command-W, the selected tab), Close Window (Shift-Command-W)
  and Close All (Option-Shift-Command-W).
- Launch window: a plain launch (and New Window) shows a compact 400x500
  window with a drop zone; it takes one or more files or folders (dropped,
  or chosen after a click). One file waits for its partner; the first
  comparison turns the window into a document window.
- File shelf (View > Toggle File Shelf, Command-/): cards for every file of
  a text comparison (A/B letter, icon, name, folder, and an action menu:
  Set as A / B, Open With, Reveal in Finder, Copy Path, Remove) and a +, ›,
  ‹ column. Opening or sending (prism) more than two files makes one
  comparison with all of them on its shelf. Edit > Select Next / Previous B
  (→ / ←), Select Next / Previous A (Option-→ / ←), Select Next / Previous
  A & B; the arrows reach the shelf only when it can use them.
- Edit > Paste to Comparison (Option-Command-V): the clipboard's text
  becomes a file of the comparison (shown as "Clipboard").
- Path bar breadcrumbs: the volume and middle folders as icons, the last
  two components named with a menu; each component lists its siblings
  (choose one to compare it instead) with Reveal in Finder, Copy Path and
  Open in Terminal or Open With. A shelf toggle at the right end.
- The full menu bar: every item and shortcut of the reference menus,
  including Edit > Spelling and Speech, View > Enter Full Screen and
  Previous / Next Conflict (for the 3-way merge), and Help > Prism
  Website, Getting Started and Send Feedback. Items of another kind of
  comparison are hidden.
- Prism > Quit and Keep Windows (Option-Command-Q): windows and their tabs
  (files, shelf, view mode, wrapping, whitespace) come back at the next
  plain launch; also on every quit when the system setting "Close windows
  when quitting an application" is off.

### Changed (milestone m10)

- A plain launch shows the launch window instead of About.
- Closing a window asks about every tab with unsaved changes before it
  asks to stop running copies, and a cancelled close (or a new edit)
  voids earlier "Don't Save" answers. Closing a background tab that needs
  an answer brings it to the front first.
- Restored windows are moved back onto a screen; restored folder levels
  that are gone, or that would leave the compared roots, open at the
  roots. Clipboard snippets are removed at quit unless a kept window uses
  them.
- Copy needs selected text; Keep Both is disabled for an inserted or a
  deleted block; a folder level's Reset Selection stays available.

### Known gaps and intended deviations (milestone m10)

- File > Save stays disabled while nothing is unsaved (the reference keeps
  it enabled): an intended deviation.
- No Registration… or Check for Updates… items: an open-source app has no
  licence to register and no update service (intended).
- Window state of test runs (PRISM_TESTING=1) goes only to the file named
  by PRISM_STATE_PATH; without it nothing is read, saved or deleted.
- The 3-way merge menu context is checked with the merge scope (m07).
- GUI checks of M10.sh (launch window, shelf, AX menus, restoration, tab
  drag-out, screenshots) await a GUI run.

### Added (milestone m05: prism, git difftool changesets, Integration window)

- `prism` sends files to the app over a Unix-domain socket
  (`~/Library/Application Support/Prism/prism.sock`, mode 0600, peers of
  other users refused) with length-prefixed JSON messages, and starts the
  app in the background when it is not running (waiting up to 20 s; an app
  started this way shows no About window). Accepts the same options as
  ksdiff for diffs: `--diff`, `--partial-changeset` (`--UUID`,
  `--relative-path`), `--changeset` with `--filelist` (folder pairs expand
  to every file), `--mark-changeset-as-closed`, `--wait`/`-w`/`--no-wait`,
  `--label`, `--file-status`, `--snapshot`/`--no-snapshot` (also accepted
  after `--`), `--supports-capability`, `--version`, `--short-version`.
  svn `diff-cmd` and `P4DIFF` argument forms are understood. Exit status 0,
  1 (errors, or the app quitting during `--wait`) or 255 (communication
  failure). See docs/spec-public/prism-cli.md.
- `git difftool` opens every changed file in one changeset window: pairs
  from the same git process (PID and start time of the nearest git, hg,
  svn, p4 or bzr ancestor) or the same `--UUID` share a window; the
  changeset stops accepting files when that process exits (kqueue
  process watch), and pairs that arrive after the window was closed open a
  new one. Temporary files (git's blob copies) are copied before `prism`
  returns.
- Changeset window (title "Changes in <folder>" or the caller's
  arguments): a sidebar with the tool icon, "N changed files", a spinner
  while files may arrive, folder groups ("Root Path" first) and rows with
  changed / added / removed glyphs; the selected file's comparison on the
  right; View > Previous File / Next File (Shift-Cmd-Up / Shift-Cmd-Down).
  A private copy shows only its file name in the path bar.
- `prism --wait` returns when the window is closed, and exits 1 within
  100 ms when the app quits.
- Prism > Integration...: installs or removes `prism` as a link in
  `/usr/local/bin` or `~/bin`. Another application's `prism` is never
  overwritten: Prism offers `prism-diff` as the link name instead.
  Git: makes Prism the default diff tool or an extra one (`difftool.prism.*`,
  `diff.tool`, `difftool.prompt` via `git config --global`), shows
  installed / out of date, and Remove restores the config byte for byte
  (comments and formatting included, and a config file that did not exist
  is removed again). A foreign `prism` earlier on the PATH is pointed
  out.
  Instructions for Mercurial, Subversion and Perforce.
- `prism://compare?url=<file URL>&url2=<file URL>` opens a comparison of
  two local regular files after asking; other hosts and `/net` /
  `/Network` paths are refused.
- Environment overrides for tests: `PRISM_SOCKET_PATH`, `PRISM_APP_PATH`,
  `PRISM_TESTING=1` (no focus stealing; enables `PRISM_INTEGRATION_ROOT`
  in release builds); `prism` forwards only the documented variables to an
  app it starts. The socket server reads requests without blocking under
  one deadline per request, and drops the oldest of too many pending
  connections.
- Libraries: `PrismProtocol` gains the wire messages, framing, socket and
  process helpers; new `PrismIntegration` (socket server, changeset
  router, snapshots, installers; no AppKit). Internal `PrismIPCStub`
  serves the protocol headlessly for scripts and CI.

### Known gaps (m05)

- Merging (`--merge`, `mergetool.prism.*`) arrives with M7; `prism`
  rejects merge options for now. (Done in m07.)
- More than two files in one diff open as consecutive pairs (no file
  shelf yet); a folder pair in a plain diff shows the "folder comparison is
  not available" message until the folder window lands.
- Installing into `/usr/local/bin` needs write access: Prism does not ask
  for administrator rights; it suggests `~/bin` or a `sudo ln` command.
- The changeset tab strip has no "+" button and changesets are not saved.
- A Prism started from the Finder with no PATH may not find git; the
  usual locations (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) are
  searched first.
### Milestone m06: editing, two-way merge and saving

Both sides of a text comparison can be edited, changes copied between
them, undone and saved back in the file's own encoding.

#### Added

- Merge menu, for the selected change:
  - Copy to Right (Cmd-Right) and Copy to Left (Cmd-Left);
  - Keep Both (Left then Right) (Opt-Cmd-Right) and Keep Both (Right then
    Left) (Opt-Cmd-Left);
  - Reset Selection (Opt-Cmd-Delete) puts the change back as it was.
  Each is one undo step. A merged change stays in the list, shown as
  resolved (no colour, selected line numbers), so "Change N of M" does
  not move; choosing again starts from the change's original lines.
- The bottom bar's merge arrows act: copy to the right or left (with
  Option, keep both), and the two pop-up segments offer the keep-both
  variants and Reset Selection.
- Free editing: a double click, or typing, over a block opens an editor
  (a TextKit 1 text view) over that block's lines; input methods,
  spelling and Services work there. It commits on focus loss, Escape or
  Cmd-Return; the text is re-diffed at once (about 50 ms for an edit of
  the 100,000-line pair, release build) and the view keeps its place.
- Undo and Redo (Cmd-Z, Shift-Cmd-Z) for edits and merges, per window.
- File > Save (Cmd-S), Save All (Shift-Cmd-S) and Revert to Saved. Files
  are written in their original encoding, byte order mark and line
  endings; the file itself is kept (permissions, links). A file whose
  encoding does not round-trip asks before saving.
- Unsaved changes show the window's edited dot and a dot after the side's
  letter in the path bar; closing such a window asks to save, and so does
  quitting.
- Guards: files in the temporary folder (`$TMPDIR`, where version-control
  tools put their snapshots) and text that could not be read in an
  encoding Prism can write back are read-only; merging or typing into
  them shows why and changes nothing.
- `PRISM_TESTING=1` keeps Prism from activating itself at launch (for
  acceptance runs next to other work).
- Files that `prism` copied as snapshots (plain diffs and changesets)
  are read-only like those in `$TMPDIR`. Showing another file of a
  changeset asks first when the current one has unsaved changes.
- `scripts/accept/M06.sh` and its CI job.

- Text tabs of folder windows take part: the folder window shows their
  edited dot, undoes their edits, and asks before a tab or the window
  closes with unsaved changes.
- Saving never overwrites a file that changed on disk since it was read
  without asking (Overwrite, Revert or Cancel); files with several hard
  links, or in folders that cannot be written, are written in place; the
  data is flushed to the disk before the file is swapped in.
- Quitting asks Save All, Review Changes, Discard Changes or Cancel, and
  counts text still open in an editor.

#### Fixed

- A re-diff that added changes could crash while the panes were laid out
  for the new rows (stale row geometry used by the scroller marks).
- Review fixes: the merged change stays selected after the re-diff, and
  copied inserts, deletions and Keep Both stay listed as resolved; the
  caret stays on its line after a re-diff; edits keep each line's own
  line ending, and pasted CR LF, CR or U+2028 breaks no longer add lines;
  layout, wrap, font and theme changes commit the editor first; a
  minimized window is brought back to ask before closing.

#### Known gaps

- The "Modifying App Bundles is Unsupported" warning is not implemented.
- The editor covers the visible part of an unchanged block longer than
  400 lines.
### Integration of m05, m06 and m09

- One Merge menu for every window: Copy to Right, Copy to Left and Reset
  Selection act on a text comparison's selected change or on a folder
  comparison's selected rows; the Keep Both pair shows only for text, and
  Start Copying Files only for folders, so Cmd-Return still commits a
  text edit.
- Quitting asks about unsaved edits first (folder text tabs included),
  then about copies still running. Closing a folder window asks to stop
  its copies, then about each text tab with unsaved changes.
- In a folder window, Undo and Redo follow the selected tab: a text tab's
  edits, or the folder tab's staging (disabled while it copies).
- With no key window (Prism in the background, as under
  `PRISM_TESTING=1`, or driven through accessibility actions), menu
  commands, their validation and Edit > Undo / Redo (with their titles)
  go to the frontmost comparison or folder window. The application object
  is now `PrismApplication` (Info.plist `NSPrincipalClass`).
  In the background the menus are validated again after each command
  and before the app idles, so accessibility clients see current titles
  ("Redo Copy to Right") and enabled states.

### Milestone m09: folder staging and copy

Folders can be synchronised: stage copies in either direction, review
them, and copy with progress, cancel and error recovery.

#### Added

- Staging in the folder window:
  - Merge menu: Copy to Right (Cmd-Right), Copy to Left (Cmd-Left), Reset
    Selection (Option-Cmd-Backspace) and Start Copying Files (Cmd-Return,
    which becomes Cancel Copying Files during a copy).
  - A button in the centre gutter of every row that can be copied: the
    pointer over it shows the possible directions, a click cycles through
    them. A staged row shows a chevron towards its destination, and its
    source side takes the status colour.
  - The same copy buttons in the bottom bar, a footer "N files to copy"
    and a Copy button that stands out while anything is staged.
  - Every staging choice can be undone and redone (Edit > Undo, Redo). The
    window shows as edited from 5 staged items.
  - Only-left items copy right, only-right items copy left, changed items
    either way; unchanged items cannot be staged.
- A summary sheet before copying: the A and B folder names, one line per
  item ("copies to B", "replaces the one in A"), a note that copies can't be
  undone, and Cancel / Copy Files. Hold Option to skip it; Settings >
  Folders > "Show a summary before copying" (on by default) turns it off.
- `FolderCore` copy engine (`FolderStaging`, `FolderCopier`):
  - items run one by one, in Finder order of their names;
  - each item is copied to a hidden temporary name next to its destination
    first, so a cancelled or failed item leaves nothing behind and the old
    destination untouched;
  - replaced destinations are moved to the Trash, never deleted;
  - symbolic links are copied as links and never followed, and a folder on
    the way that is a symbolic link out of the compared folder stops the
    item;
  - modification times are kept to the nanosecond, with modes, flags,
    extended attributes and ACLs, so copied items compare as unchanged;
    files are cloned on APFS when possible;
  - progress weighted by bytes, cancellation within one 1 MiB chunk;
  - on an error, a sheet offers Skip, Stop Copying and Try Again;
  - a process-wide lock refuses a copy that overlaps one already running
    in another window; on case-insensitive volumes it compares paths with
    case and Unicode form folded;
  - a replaced item is first parked, under its own name, in a hidden
    folder next to it; the new item is renamed in, and only then is the
    old one trashed. If any step fails, the original is put back. File
    locks (uchg) are applied last, so locked items copy and replace;
  - every step after opening the destination folder works relative to
    that open folder (openat, fstatat, renameatx_np, fcopyfile, futimens)
    and the item's identity is checked again before it is trashed, so a
    folder swapped for a symbolic link mid-copy cannot redirect it;
  - an existing destination whose name differs only in case or Unicode
    form (`README` for `Readme`, two spellings of `café`), or that
    appeared after the item was staged as new, is never replaced: the item
    fails with a name-conflict error;
  - folders created for an item are removed again when it fails or is
    cancelled, and leftovers of an interrupted copy (hidden `.prism-copy-`
    items) are cleaned up when a level is listed, with a parked original
    put back when its name is free.
- Closing a tab or window, or quitting, while files are being copied asks
  first; stopping removes the partial item.
- Undo and Redo are disabled while a copy runs.
- A warning before staging copies inside an application bundle, with a
  "don't warn me again" box.
- `PrismBench foldercopy` stages and copies from the command line, with a
  plain trash directory (used by `scripts/accept/M09.sh`).
- Acceptance runs: `PRISM_TESTING=1` keeps Prism from activating itself,
  and `PRISM_TRASH_DIR` sends replaced items to a directory instead of the
  Trash. `scripts/accept/tools/axpress.swift` drives the app by AX actions
  in the background.

#### Known gaps

- Staging belongs to a tab: a choice staged in a drilled-down tab is not
  shown on the parent tab's folder row.
- The original's per-file "Preparing/Moving" stages are reduced to
  Preparing, Copying and Replacing.
- Staged choices are not saved with window state, and closing a window with
  staged (but not running) copies does not ask.

### Milestone m08: folder comparison (read-only)

Two folders compare side by side, level by level, and stay current while
files change on disk.

#### Added

- `FolderCore` library, the folder-comparison engine:
  - `FolderSession` compares two folder trees. The first rows of a level
    come from a one-level listing of both sides (well under a millisecond
    for typical folders); a deep pass then walks both trees with a fixed
    pool of 8 worker threads and resolves every folder row.
  - Listing uses `getattrlistbulk` on APFS and HFS+ and `fts` on other
    volumes (SMB, NFS, FAT, exFAT), or when bulk attributes are refused.
  - Folder rows compare by an order-independent digest of the path, size
    and modification time of every item below them; folder sizes are the
    totals of their files.
  - Rows are matched by key, then paired by exact (case-sensitive) name as
    changed, with the newer side by modification time; the rest are
    left-only or right-only. Rows are in Finder order.
  - Symlinks and Finder aliases compare by name (a symlink shows the size
    of its target); unreadable items compare by name; `.DS_Store` is always
    skipped; hidden items only when asked for.
  - Filters (Changed, Unchanged, Unmatched), counts over all rows, and
    sorting by name, date or size of either side.
  - Live refresh: an FSEvents stream (latency 0.05 s) re-lists only the
    folders that changed and patches the digests of their ancestors; a
    touched file shows within about 15 ms on a 200,000-file tree, with no
    rescan.
  - Optional content check (off by default): changed pairs of same-size
    files, and changed folder pairs, are confirmed by comparing bytes, so
    files that were only touched show as unchanged.
- Folder window: `open -a Prism dirA dirB`, File > Open with two folders,
  or two folders dropped on the Dock icon open a folder comparison.
  - Two tables (Name, Date Modified, Size) with a centre gutter, scrolled
    and selected together; an item missing on one side leaves a blank
    row there, so the rows stay aligned.
  - Rows tinted by status: red for left-only, green for right-only,
    lavender for changed; the selection takes the status colour. Folder
    rows show a spinner in the gutter until their contents are known.
  - Bottom bar "Show: N Changed, N Unchanged, N Unmatched" with live
    counts; the checkboxes hide and show rows.
  - Column headers sort by name, date or size of that side.
  - View > Open Selection (Return) or a double-click opens a folder pair in
    a new tab, "src (left) | src (right)", next to its parent, and a file
    pair in a text tab; Command-double-click opens a new window. Cmd-W
    closes the current tab. Next/Previous Change step through the
    differing rows.
  - Rows update live as files change on disk.
- Settings > Folders: "Show hidden files" and "Compare file contents" (both
  off by default); changing them rescans open folder windows.
- `PrismBench folders`, `foldergen`, `folderperf` and `folderwatch`: rows
  of a level, a generated 200,000-file tree pair, the scan budgets and the
  live-refresh latency.
- `scripts/accept/M08.sh` and the `accept-m08` CI job.

#### Fixed during review (m08)

- A folder renamed into the name of another (for example two folders
  swapped by renaming) is rescanned: subtrees are reused only when the
  folder's inode is unchanged.
- A replaced comparison root, or events dropped at a root, now run a full
  scan (counted as one), re-list every open level on both sides, and
  apply the rest of the event batch afterwards.
- Content checks are queued, at most 8 at a time, and stop when the
  comparison closes, instead of parking one thread per pair.
- A folder that cannot be listed is reported (`leftUnreadable` /
  `rightUnreadable`, "Folder not readable" in the window) instead of
  looking empty; a folder that can be read but not searched is listed
  through `fts`.
- The FSEvents stream starts from the moment a level was first listed, so
  changes made before the deep pass starts are not missed.

#### Performance (200,000 files in 20,000 folders per side, warm)

- First rows: 0.2 ms. Deep pass: 0.8 s. Peak memory: 23 MB (engine).
- In the app: first rows within a few milliseconds of the window opening,
  the main thread never blocked for more than about 55 ms.

#### Known gaps (m08)

- Read-only: staging and copying files (the gutter arrows, the copy
  buttons and the Merge menu) arrive with m09.
- The tab strip is minimal: tabs can be selected and closed (Cmd-W), but
  there is no new-tab button, reordering or tab menu yet (m10).
- A row present on one side only opens nothing when it is a file; a
  one-sided folder opens with an empty side.
- Finder aliases are not detected on volumes scanned with `fts`; there
  they compare like ordinary files.
### Added (milestone m04: full text viewing)

- Fluid layout (View > Fluid, Cmd-2): unpadded panes joined by a 70 pt
  gutter of connector lines from each difference's lines in A to its lines
  in B, a marker line where a side has no lines, and block-by-block
  proportional scroll sync.
- Unified layout (View > Unified, Cmd-3): one column with A and B line
  numbers, A/B marks on changed lines, each change as its A lines then its
  B lines, outlined.
- The layout switcher in the bottom bar is live, and the last layout used
  is remembered for new comparisons (Blocks until one is chosen).
- Find (Edit > Find: Find... Cmd-F, Find Next Cmd-G, Find Previous
  Shift-Cmd-G, Use Selection for Find Cmd-E, Jump to Selection Cmd-J): a
  find bar with an A/B scope, previous/next, "Nth of M results in A (K
  more in B)" with a link to the other side, everything but the matches
  veiled, the current match as a yellow pill, Close and Esc. Matching is
  literal, case- and diacritic-insensitive.
- Ignore Whitespace per window (View menu, Shift-Cmd-', and a bottom-bar
  checkbox): re-diffs ignoring spaces and tabs at line edges, keeping the
  scroll position; the text shown is unchanged.
- Wrap Lines per window (View menu, Shift-Cmd-K) and Settings > Text >
  "Turn on Wrap Lines for new comparisons". Rows grow to the wrapped height of
  their taller side, so Blocks stays exactly aligned, also while resizing.
- A dot per difference (and a tick per find match) in the scroller track.
- Text selection in the panes: click-drag, double click (word), triple
  click (line), shift-click, Select All, Copy; Up and Down move the
  current line, whose number is bold.
- Accessibility: every visible line is an element whose label is its side
  and number and whose value is its text; the current line is the focused
  element.
- Bottom bar: merge-arrow group (inactive until merging arrives) and the
  whitespace checkbox.

### Fixed (carried over from m03)

- A very long line no longer stalls drawing: lines are split into chunks
  shaped only when on screen, highlight offsets are cached per line, and
  the document is at most 1,000,000 pt wide (wrap to reach beyond).
- Changing the text size keeps the top line, the part of it scrolled past
  and the first visible column.
- Emoji and other four-byte characters count as three columns when sizing.
- After a reload fails, Previous/Next Change no longer drive the old
  comparison.
- The loading spinner no longer flashes before the 150 ms threshold.
- Theme colours are made once per theme change instead of on every draw.
- The Blocks change bar on the divider is 2 pt wide.

### Fixed (m04 review)

- Long non-ASCII lines are placed, hit-tested and wrapped by measured
  width (no gaps or overlaps between chunks, no cut or blank wrapped
  lines); chunk cuts never split a character, and only 16 chunks per line
  stay shaped.
- Copy never drops a line when an offset falls inside a character, and a
  line's terminator is copied exactly when the selection passes it (triple
  click copies "line\n").
- Find steps stay cheap with hundreds of thousands of matches; match
  offsets are right after a leading byte order mark; highlights show in
  the middle of long word and match ranges.

### Known gaps (m04)

- Merge arrows are shown but inactive (m06). Editing is not available.
- Wrapping breaks at character boundaries, not at word boundaries. In
  right-to-left runs it slices at the plain wrap width.
- Without wrapping, text beyond 1,000,000 pt of a line cannot be scrolled
  to.
- The font default stays at 11 pt, as specified; the larger text in the
  reference screens comes from a chosen font.

### Added (milestone m03: two-pane text viewer, Blocks layout)

- The app opens comparisons: `open -a Prism a b`, File > Open (choose two
  files, or one and then its partner), files dropped on the Dock icon or on
  a window (two files replace both sides, one file replaces the side it is
  dropped on), or `Prism.app/Contents/MacOS/Prism a b`. A plain launch
  still shows About.
- Comparison window (1354 x 908 by default, at least 612 x 443): a tab
  strip with "a | b" and a file-count badge, a path bar with A and B
  breadcrumbs and a swap button (Edit > Swap A & B, Cmd-\), and a bottom
  bar with the layout switcher (Blocks; Fluid and Unified are shown
  disabled), "Change N of M" and previous/next buttons.
- Blocks view drawn with CoreText, one line at a time, only for the rows
  on screen: line numbers, green/red/violet bands for added, removed and
  changed lines, stronger highlights on the changed words and insertion
  marks, outlined padding boxes where one side has fewer lines, a 1 pt
  change marker on the divider, line-end marks on changed lines, and a
  stronger band and filled line-number cell for the selected change.
  Both panes share one row layout, so they stay aligned exactly and scroll
  together on both axes.
- Navigation: View > Previous/Next Change (Cmd-Up/Cmd-Down, wrapping),
  clicking a changed line or its number, View > Blocks (Cmd-1), and
  Increase/Decrease Text Size (Cmd-+/Cmd--) per window.
- Four built-in themes (Multicolored or Single Color, Light or Dark) in a
  JSON theme format. Default font: the system monospaced font at 11 pt.
- Settings > Text: Light/Dark background, Multicolored/Single Color,
  font with Change..., and "ignore whitespace at line edges" for new
  comparisons. Open windows follow theme and font changes at once.
- Files are read and diffed off the main thread; a "Comparing..." view
  appears when that takes longer than 150 ms, and closing the window
  cancels the diff. Files are read as UTF-8 (ill-formed bytes are shown as
  U+FFFD) through a small `TextSource` protocol that the encoding-aware
  importer will replace.
- `PRISM_PERF_LOG=<file>` makes the app append JSON lines (first paint,
  selection, scroll bench) for benchmarks; `PRISM_BENCH_SCROLL=1` adds a
  display-link scroll stress run.
- `scripts/accept/M03.sh`, with Vision-based OCR and pixel probes for the
  screenshot checks, and an `accept-m03` CI job (headless).

Measured on an Apple-silicon MacBook Pro (120 Hz), 100k-line pair
(944 changes): first paint 0.22 s after process start (55 ms after the
window starts loading; read 13 ms, diff 9 ms), 120 MB resident, longest
main-thread stall while loading 21 ms; scroll stress over the whole
document 0 missed frames at 120 Hz (2.9 ms average frame work).

### Known gaps (m03)

- Read-only: no selection, copy, find or editing yet; no Fluid or Unified
  layout, word wrap, "Ignore whitespace" toggle in the window, overview
  dots in the scroller or wrap-around notice.
- Tab characters are expanded (width 4) but get no visible mark on
  changed lines.
- One comparison per window; the "+" tab button, file shelf and breadcrumb
  menus come later.
- Only UTF-8 input; other encodings arrive with the text importer.

### Milestone m02: text import

Every file is decoded before it is compared, and `prism sniff` reports how.

#### Added

- `TextImport` library, the import API for the app and the tools:
  `TextImport.load(url)` and `TextImport.decode(bytes, fileName:)` return an
  `ImportedText` with the kind (`text`, `document`, `binary`, `directory`,
  `missing`), the text as UTF-8, the source encoding, the byte order mark,
  line-ending counts and style, and `encoded()`, which writes the text back
  byte for byte. Options: a size limit (default 2 GiB), the 50 MiB limit
  for reading binary-looking files as text, a language hint for encoding
  detection, and a progress callback.
- Encoding detection in order: byte order mark (UTF-8, UTF-16, UTF-32),
  binary check, BOM-less UTF-16, UTF-8 validity, Foundation's detector,
  then Windows-1252 and ISO-8859-1. 100 MB imports in about 0.05-0.5 s
  (UTF-8, UTF-16, Latin-1) and 1.3 s (Shift JIS).
- Binary detection: known signatures (PNG, JPEG, GIF, TIFF, Mach-O, ELF,
  zip, gzip, xz, 7z, zstd, tar, SQLite, WebAssembly), NUL
  bytes and the share of control characters, with file types as a tie
  breaker.
- Plain-text extraction from RTF, RTFD, DOC, DOCX, WordML and ODT (macOS
  text system) and from PDF (PDFKit); binary property lists open as XML.
- Files with a byte order mark are always text: ill-formed units and a
  stray last byte show as U+FFFD and are flagged as not round-tripping.
  BOM-less UTF-16 is recognised when truncated or mostly CJK, and
  binary-looking files of up to 50 MiB in a detectable single-byte encoding
  open as text.
- `prism sniff [--json] FILE ...`: kind, encoding, BOM, line endings, line
  count, final newline, size and round-trip safety of each file.
- `prism diff` and `prism merge3` compare decoded text: UTF-16, Latin-1 or
  Shift JIS files diff against UTF-8 ones, documents by their text, and
  binary files are refused with exit status 2.
- `Tests/corpus/encodings/`: the text-import corpus, its expected
  classification and its generator.

#### Changed

- Word highlights follow Unicode word boundaries: letters of any script
  form words, each Han ideograph and hiragana is a word, katakana runs stay
  together. A change inside a CJK line now highlights only the changed
  characters, not the whole run.
- Changed lines in a block are paired by the length of their common text in
  characters, not in UTF-8 bytes.
- A difference only in the final newline now shows at `--ws 1` and
  `--ws 2` too, as a change of the last line.
- The side-by-side view stops laying out a line once it overflows its
  column, so very long lines cost no more than short ones.
- `prism merge3` refuses a BASE of 2 GiB or more instead of failing inside
  the engine.

#### Known gaps

- Encoding detection of short non-UTF-8 files is a guess; the language of
  the current locale steers it. Only ISO-8859-1 and Windows-1252 are
  decoded without Foundation. For other encodings round-trip safety is
  checked on the first MiB only; saving must verify the whole text.
- Words in Thai, Lao, Khmer and Burmese, which need a dictionary to
  segment, stay whole runs; Chinese and Japanese are split per character.
- Documents are recognised by extension (RTF and PDF also by content); a
  DOCX or ODT piped through standard input is read as a zip, so binary.
- The version number is unchanged until the milestone is merged.

## [0.2.0] - 2026-10-11 (milestone m01)

Milestone M1: the comparison engine and the headless `prism diff` and
`prism merge3` commands. The app does not show comparisons yet.

### Added

- `DiffCore`, the text comparison engine (pure Swift, no Foundation):
  - line diff over interned lines (lines split with `memchr`): common
    prefix and suffix trimmed, lines unique to both sides used as anchors to
    split the problem, a discard pass for lines that cannot match, then
    linear-space Myers with an xdiff-style cost cap (`max(256, sqrt(N))`) so
    pathological inputs stay fast;
  - word refinement of changed regions with line pairing and
    whitespace-equal pre-pairing, run in parallel for large changes and
    limited to 500,000 tokens per multi-line region (beyond that a region
    stays a line-level delete plus insert; one line against one line gets 16
    times that, counted after its common prefix and suffix);
  - whitespace modes 0 (every byte), 1 (LF, CRLF and CR are equal) and 2
    (also ignore blanks at the line edges); ranges always point into the
    original bytes;
  - change classification (insert, delete, change; word hunks replace,
    insert-only, delete-only) and final-newline flags;
  - cooperative cancellation (`CancellationFlag`, `cancellableDiff`,
    `asyncDiff`), checked inside Myers, refinement, pairing and interning;
  - UTF-16 columns for word ranges, for AppKit;
  - a unified line sequence and `diff -u` hunks with git-style headers;
  - a three-way merge model (base to A, base to B; regions built in base
    coordinates from overlapping edits, automatic choices and conflicts,
    five resolution choices, fixed-format JSON).
- `prism diff [--ws 0|1|2] [--json | --unified | --side-by-side] [--color]
  [--width N] A B`. Unified output (the default) follows `diff -u` (all
  removed lines of a run before its added lines), with
  `\ No newline at end of file` markers, and applies with patch(1) when
  both inputs are valid UTF-8 with LF or CRLF line endings (see Known
  gaps); the side-by-side view takes its
  width from `--width`, `$COLUMNS` or 160; `--json` writes the blocks and
  word ranges (bytes and UTF-16) in a fixed, file-name-free format. Exit
  status 0 when the files compare equal, 1 when they differ, 2 for a usage
  error, an unreadable file or a failed write. Inputs may be pipes,
  process substitutions or `-` for standard input.
- `prism merge3 [--ws 0|1|2] [--json] BASE A B`: the automatic merge, its
  regions and conflicts. Exit status 0 when everything merged, 1 when a
  conflict remains, 2 on errors (including A and B together reaching
  2 GiB).
- `docs/spec-public/prism-cli.md`: the command grammar, exit codes and both
  JSON formats.
- Twelve hand-written three-way merge cases in `Tests/corpus/merge/` with their
  expected JSON, pinned by `merge.sha256`, plus goldens for the `prism diff`
  JSON, unified and side-by-side output.
- `PrismBench`, an internal release-mode bench (an executable target that is
  not a product and is never copied into `Prism.app`). Each subcommand prints
  `PASS`/`FAIL` lines plus `key=value` lines and exits 0 only when every
  check passes:
  - `perf [--scale F] [--repeat N]`: median in-process engine time on
    memory-mapped inputs, after one warm-up run, against the M1 budgets;
  - `property N`: the seeded property suite (N=5000 gives 30,000 cases);
  - `cancel`: latency from `cancel()` to return on diff20k and m1, on
    disjoint 300k- and 1M-line pairs, on 2000 lines of 7 KB punctuation and
    on one-line minified JSON pairs of 8 and 32 MB;
  - `gitcheck`: line-hunk counts against
    `git diff --no-index --patience -U0`, run with no user or system
    configuration.
- `scripts/accept/M01.sh`, the M1 acceptance script (headless; it also runs
  in CI with `PRISM_PERF_SCALE=3`), and an `accept-m01` CI job that
  generates the large corpus inputs first.
- The milestone pre-release also carries `prism-<version>-macos-arm64.zip`,
  the signed `prism` tool on its own, built by `scripts/bundle.sh`.

### Changed

- A failed write to standard output (closed descriptor, broken pipe) is now
  reported: `prism` exits 2 and `ksdiff` exits 1, after one line on standard
  error, instead of exiting 0 with the output lost. A broken pipe behaves as
  in diff(1): with the default `SIGPIPE` disposition the tool is ended by
  the signal; when `SIGPIPE` is ignored it exits as for any failed write.
  `M00.sh` checks this with a pipe that is broken before the tool starts, so
  the check no longer races.

### Performance

Measured on an Apple M-series machine (release build, engine time only,
median of 5 runs after a warm-up, `PrismBench perf`):

| Case | Measured | Budget |
|---|---|---|
| big (100k lines, 944 changes) | 7.7-10.9 ms | 40 ms, and 130 ms on any machine |
| m1 (1M lines, 10 edits) | 78-107 ms | 400 ms |
| crlf, ws=0 (100k lines, LF vs CRLF) | 77-82 ms | 300 ms |
| diff20k (20k fully different lines) | 9.8-10.8 ms | 2000 ms |
| property 5000 | 30,000 cases, 0 failures, 3.8 s | 0 failures |
| cancel latency, diff20k at 100/50/10 ms | 0.02-0.05 ms | 50 ms |
| cancel latency, m1 at 50/10 ms | 0.85-1.4 / 7.4-9.9 ms (it finishes in about 90 ms, before the 100 ms point) | 50 ms |
| cancel latency, 2000 lines x 7 KB punctuation, no valve, at 200/100/50/10 ms | 0.4-0.6 ms | 50 ms |
| cancel latency, one-line JSON 8 MB / 32 MB (finish in about 110 / 135 ms) | 0.2-0.8 ms | 50 ms |
| git --patience hunks: a/b, big, slider, m1, diff20k | 7, 942, 1, 10, 1, all equal to git | equal |

### Known gaps

- No encoding detection (planned for M2): input is treated as bytes and
  shown as UTF-8, with invalid bytes as U+FFFD.
- An ambiguous insertion (a "slider") is placed by the latest-position
  rule, not by git's indent heuristic, so hunk positions can differ from git
  by a line (counts are equal).
- Hunk counts match git on the whole corpus, but can differ from it on
  large rewrites.
- `--color` is never turned on automatically: there is no terminal
  detection.
- The word tokenizer works on ASCII byte classes; it is not Unicode- or
  locale-aware.
- Above 500,000 tokens a changed region of several lines is not refined to
  words; it shows as one delete plus one insert. One line against one line
  is refined up to 8,000,000 tokens between its common prefix and suffix
  (which bounds its memory to a few hundred MB); a longer edited span, such
  as scattered edits across a 30 MB minified file, also shows as a delete
  plus an insert.
- Whitespace-equal pre-pairing is a speed shortcut, not part of the
  reference alignment: in a changed region over 64 KiB, lines that are
  equal ignoring whitespace and line endings are paired before the word
  alignment, even at `--ws 0`. On such regions the pairing shown can differ
  from a single word alignment of the whole region.
- Unified output is not byte-exact for every input, so patch(1) can reject
  it: invalid UTF-8 bytes are written as U+FFFD, and a line ended by a lone
  CR is followed by an added LF (patch(1) itself only splits lines on LF).

## [0.1.0] - 2026-10-11 (milestone m00)

Milestone M0: foundations. There is no diff functionality yet.

### Added

- Apache-2.0 `LICENSE`, `NOTICE` with a non-affiliation statement, and
  `CONTRIBUTING.md` with the clean-room contribution rule and DCO sign-off
  (`git commit -s`).
- Guard scripts in `scripts/ci/`: SPDX headers (`check-spdx.sh`), clean-room
  rules (`check-cleanroom.sh`) and DCO sign-off (`check-dco.sh`).
- SwiftPM workspace (Swift 6 language mode; `scripts/ci/build-strict.sh`
  builds with `-warnings-as-errors`, so a warm build cache cannot hide a
  warning) with these modules, each with a
  swift-testing suite:
  - `DiffCore` (no Foundation), `TextImport`, `FolderCore`, `PrismProtocol`;
  - `KsdiffCLI`, built as the `ksdiff` executable;
  - `PrismTool`, built as the `prism` executable;
  - `PrismApp`, the AppKit application.
- `ksdiff --version`, `--short-version` and `--help`; `prism --version` and
  `--help`. `ksdiff` also accepts one of `-w`/`--wait` and `--no-wait`, and answers
  a leading `--short-version` whatever follows it. Unknown arguments are
  usage errors (exit status 1).
- `Prism.app` with App, File, Edit, Window and Help menus (Shift-Cmd-W Close
  Window, Option-Shift-Cmd-W Close All, Cmd-W Close; Option alternates Quit
  and Keep Windows, Minimize All and Zoom All; Help opens the online
  documentation) and an About
  window, shown at launch (`--no-about` or `PRISM_SHOW_ABOUT=0` skips it).
- `scripts/bundle.sh`: builds `build/Prism.app` and `build/Prism-<version>.zip`
  with the Command Line Tools only. The bundle embeds `Contents/Helpers/ksdiff`
  and `Contents/Helpers/prism`, has a generated placeholder icon, and is
  ad-hoc signed with the hardened runtime.
- Golden corpus in `Tests/corpus/` (synthetic fixtures with a checksum
  manifest, a reproducible git repository builder and a generator for large
  inputs) and a golden-file test harness (`PRISM_UPDATE_GOLDEN=1` rewrites
  golden files).
- Acceptance framework (`scripts/accept/lib.sh`: app launch and quit,
  Accessibility UI driver, window lister, screenshots) and
  `scripts/accept/M00.sh`, which runs in GUI mode locally and headless with
  `CI=true`.
- GitHub Actions workflow on `macos-15`: guards, strict build and tests,
  bundle, headless acceptance, artifact upload, and a pre-release for `m*`
  tags.

### Known gaps

- No diff functionality: text, folder and git comparison arrive in later
  milestones.
- The app is ad-hoc signed and not notarized (planned for M11). Gatekeeper
  asks for confirmation on first launch.
- The `m00` GitHub pre-release is created only by the CI release job when
  the tag is pushed; it was not created locally.
- The CLI target is named `KsdiffCLI`, not the all-capitals spelling in the
  milestone plan, because the clean-room identifier guard rejects names that
  start with two capital letters K and S followed by another capital.
- The Command Line Tools linker prints "search path ... not found" warnings
  on every link; `build-strict.sh` allowlists these two exact lines.
- With the Swift 6.4 Command Line Tools, a test build from a clean `.build`
  always fails to find the swift-testing macro plugin (a toolchain bug).
  `Package.swift` passes the building toolchain's own plugin directory to the
  test targets when that toolchain has one (the CLT layout), so plain
  `swift test` works; it never points an Xcode build at the CLT plugin
  (see `CONTRIBUTING.md`, checked by `scripts/tests/manifest-selftest.sh`).
- The scrubbed public specs are not written yet: `docs/spec-public/` holds
  only the README that describes the public/private boundary.
- On case-insensitive disks `tests/corpus` and `Tests/corpus` are the same
  directory; git tracks it as `Tests/corpus`.
