# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository.

## Project

Prism is a native macOS (Apple silicon, macOS 14+) file and folder comparison
app with a `prism` command-line tool, written in Swift and AppKit. It is a
clean-room re-implementation of an earlier commercial app; see the end of
[README.md](README.md).

## Layout

| Path | What it is |
|---|---|
| `Sources/DiffCore` | Diff engine (line and word diff, three-way merge). Pure Swift, **no Foundation**. |
| `Sources/TextImport` | Reading files: encodings, line endings, binary detection, document conversion. |
| `Sources/FolderCore` | Folder scanning, comparison, live refresh, copy engine. |
| `Sources/PrismProtocol` | Shared constants, version (`PrismInfo`), socket wire format. |
| `Sources/PrismClient` | The app-integration side of `prism` (ksdiff-compatible options). |
| `Sources/PrismIntegration` | The app's socket server, changesets, CLI and git-config installers. |
| `Sources/PrismTool` | The `prism` executable: `diff`, `sniff`, `merge3`, or open files in the app. |
| `Sources/PrismApp` | The AppKit app. |
| `Sources/PrismBench`, `Sources/PrismIPCStub`, `Sources/DiffCheck` | Internal tools for benchmarks and tests; never shipped. |
| `Plugins/VersionPlugin` | Build-tool plugin that compiles `VERSION` into `PrismInfo.version`. |
| `Tests/` | Unit tests, the test corpus, `PrismTestSupport` and `PrismTestWindowGuard`. |
| `scripts/` | `bundle.sh`, `release.sh`, `ci/` guards, `accept/` acceptance scripts, `perf/`. |

## Build and test

Only the Xcode **Command Line Tools** are needed (no Xcode).

```
swift build -c release            # build
swift test                        # all tests
scripts/ci/build-strict.sh        # release build with warnings as errors, then all tests
scripts/bundle.sh                 # assemble and ad-hoc sign build/Prism.app
CI=true scripts/accept/M01.sh     # one milestone's headless acceptance checks
```

## Rules

- **Clean room.** Never copy code, strings, icons or other assets from the
  original app, and never use its class-name prefixes. `scripts/ci/check-cleanroom.sh`
  and `scripts/ci/cleanroom-audit.sh` enforce this. Write UI text in your own words.
- Every source file starts with `// SPDX-License-Identifier: Apache-2.0` and
  `// Copyright 2026 Paolo Di Tommaso` (`scripts/ci/check-spdx.sh`).
- Commits are signed off (`git commit -s`, checked by `scripts/ci/check-dco.sh`).
  The default branch is `master`.
- Zero warnings under Swift 6 strict concurrency.
- **No GUI from automation.** Do not launch `Prism.app` or drive it (osascript,
  screen capture) from an agent session on a developer's machine; GUI checks run
  in CI. `scripts/accept/M00.sh`, `M03.sh` and `M04.sh` launch the app.
  Unit tests may create windows: the `PrismTestWindowGuard` test target keeps
  them invisible (`PRISM_SHOW_TEST_WINDOWS=1` shows them).
- Tests work only in temporary folders. Never touch the user's `~/.gitconfig`,
  `/usr/local/bin`, `~/bin` or Trash; use `GIT_CONFIG_GLOBAL`, a temporary
  `HOME` and the `PRISM_*` test variables (`PRISM_TESTING=1`,
  `PRISM_SOCKET_PATH`, `PRISM_STATE_PATH`, `PRISM_TRASH_DIR`, `PRISM_APP_PATH`).

## Release process

The release is fully automated and lives in one script, `scripts/release.sh`,
which runs the same way locally and in GitHub Actions.

- **Version:** the `VERSION` file at the repository root is the only place the
  version is written (SemVer, e.g. `1.0.0`; a suffix such as `1.1.0-rc1` makes a
  GitHub pre-release). The build number comes from `PRISM_BUILD_NUMBER`
  (default `1`; CI uses the run number).
- **Release notes:** `CHANGELOG.md` must have a dated `## [<version>] - YYYY-MM-DD`
  section. It becomes the release notes, including its "Unverified on screen"
  caveats.
- **Trigger:** push a commit to `master` whose message contains `[release]`.
  After all CI checks pass, the `release` job in `.github/workflows/ci.yml`
  runs `scripts/release.sh`. Pushes without `[release]`, and pull requests,
  only run the checks.
- **What `scripts/release.sh` does:**
  1. Preflight: tools, macOS arm64, clean tree, valid `VERSION`, CHANGELOG
     section present, tag `v<version>` not already used.
  2. Clean build, then `scripts/ci/build-strict.sh` (zero warnings, all tests).
  3. Guards (SPDX, clean room, clean-room audit) and the headless acceptance
     scripts.
  4. `scripts/bundle.sh`, signature verification, and a check that every
     version string equals `VERSION`.
  5. Packaging into `dist/`: `Prism-<version>-macos-arm64.zip` (the app, with
     the `prism` command inside), `SHA256SUMS`, `release-notes.md`.
  6. Publishing: tags `v<version>`, pushes that tag, and creates the GitHub
     release with the `dist/` files.
- **Rehearsal:** `scripts/release.sh --dry-run` runs every step except
  publishing (no tag, no push, no upload). `PRISM_RELEASE_SKIP_CLEAN=1`,
  `PRISM_RELEASE_SKIP_TESTS=1` and `PRISM_RELEASE_SKIP_ACCEPT=1` speed up local
  dry runs; they are refused for a real release.
- **To cut a release:** bump `VERSION`, add the CHANGELOG section, and commit
  on `master` with `[release]` in the message. Never create `v*` tags by hand.

The distribution is a zipped, ad-hoc-signed app (no notarization, DMG,
Homebrew cask or auto-updater). Users download new versions from GitHub
Releases; the README explains clearing the quarantine flag.
