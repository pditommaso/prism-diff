# Contributing to Prism

Thanks for your interest in Prism. This document explains how to build the
project, the rules every contribution must follow, and how commits are checked.

## Building and testing

Prism uses the Swift 6 **Command Line Tools only**. Do not add Xcode projects,
`xcodebuild` steps or XCUITest suites; everything must work with SwiftPM and
plain shell scripts.

```sh
swift build                 # debug build
swift test                  # unit and golden tests
swift build -c release      # release build
scripts/ci/build-strict.sh  # release build that fails on any warning, then tests
scripts/bundle.sh           # assemble and ad-hoc sign build/Prism.app
scripts/release.sh --dry-run  # the full release, without publishing (see Releasing)
```

Tests use swift-testing (`import Testing`); XCTest is not available with the
Command Line Tools. The Swift 6.4 Command Line Tools do not put the
swift-testing macro plugin on the compiler's search path, so from a clean
`.build` every test build would fail with "plugin for module 'TestingMacros'
not found". `Package.swift` adds `-plugin-path` for that directory to the test
targets, so plain `swift test` works; nothing extra is needed. It takes the
directory from the toolchain that is building (the one whose
`libPackageDescription` the manifest runs with), never from a second toolchain
on the same machine, and adds nothing when that toolchain lacks it (Xcode).
`scripts/tests/manifest-selftest.sh` checks this.

The code is compiled in Swift 6 language mode with strict concurrency checking,
and the build must produce zero warnings: `build-strict.sh` compiles with
`-warnings-as-errors` (a cached build would not reprint an old warning), and
`scripts/tests/build-strict-selftest.sh` checks that it does.

Milestone acceptance scripts live in `scripts/accept/` and share the helpers in
`scripts/accept/lib.sh` (checks, app launch and quit, System Events UI
driving, window capture). UI driving needs the Accessibility permission for
the terminal; with `CI=true` the helpers fall back to headless checks. Check
the helpers themselves with:

```sh
scripts/accept/tests/lib-selftest.sh         # helper logic only
scripts/accept/tests/lib-selftest.sh --app   # also drives build/Prism.app
```

Before pushing, run the repository guards:

```sh
scripts/ci/check-spdx.sh        # licence headers
scripts/ci/check-cleanroom.sh   # clean-room guard
scripts/ci/check-dco.sh         # sign-off on every commit (master..HEAD)
```

## Releasing

The `VERSION` file at the repository root (for example `1.0.0`, or
`1.1.0-rc1` for a pre-release) is the only place the version is written.
`Plugins/VersionPlugin`, a SwiftPM build-tool plugin, compiles it into
`PrismInfo.version` on every build, so Info.plist, the About window,
`prism --version` and `Prism --version` all follow it. The build number
(`CFBundleVersion`) comes from `PRISM_BUILD_NUMBER` at build time (default
`1`; CI uses its run number).

To release:

1. Bump `VERSION`.
2. Add a dated `## [<version>] - YYYY-MM-DD` section to `CHANGELOG.md`, with
   its `### Unverified on screen` caveats; it becomes the release notes.
3. Commit on master with `[release]` in the commit message. Once all CI
   checks pass, the `release` job runs `scripts/release.sh`, which rebuilds
   and re-checks everything, tags `v<version>`, pushes that tag and
   publishes the GitHub release (marked as a pre-release when the version
   has a `-suffix`).

To rehearse locally, run `scripts/release.sh --dry-run` on a clean working
tree: it runs every step and writes `dist/` (both zips, `SHA256SUMS`,
`release-notes.md`) but tags, pushes and publishes nothing. For quicker
iterations a dry run accepts `PRISM_RELEASE_SKIP_CLEAN=1`,
`PRISM_RELEASE_SKIP_TESTS=1` and `PRISM_RELEASE_SKIP_ACCEPT=1`; a real
release refuses them.

## Clean-room rule

Prism is an independent, clean-room implementation of a file and folder
comparison tool. Its behaviour is modelled on publicly observable features of
existing tools, in particular Kaleidoscope, but **none of their material may
enter this repository**. By contributing you confirm that:

1. Your contribution contains no code, user-interface text, icons, images,
   sounds, other assets, or class, method or file names derived from
   Kaleidoscope or any other proprietary diff tool.
2. You have not inspected, disassembled, decompiled or otherwise analysed the
   binary of such a tool, and have not read the resources inside its
   application bundle (nib files, string tables, images, plists and so on), in
   order to produce your contribution.
3. You are not adding screenshots, screen recordings or menu dumps of another
   application. No images of any kind belong under `docs/`.
4. The only description of intended behaviour you rely on is the material in
   [`docs/spec-public/`](docs/spec-public/README.md), which is written in our
   own words, plus your own independent design.

All user-visible text must be written in our own words. The CI clean-room
guard (`scripts/ci/check-cleanroom.sh`) rejects common signs of copied
material, but it is a safety net, not a substitute for following the rule.
Maintainers who keep a private research workspace can set `PRISM_DIRTY_ROOT`
to it; the guard then also rejects any file that is a byte-for-byte copy of
its notes, screenshots or specifications.
If you are unsure whether something is acceptable, ask in an issue before
writing code.

## Developer Certificate of Origin (DCO)

Every commit must be signed off to certify that you wrote the change or
otherwise have the right to submit it under the project's licence, as described
by the Developer Certificate of Origin, version 1.1:
<https://developercertificate.org/>.

Sign off by committing with `-s`:

```sh
git commit -s -m "area: short summary"
```

This adds a trailer such as:

```
Signed-off-by: Jane Doe <jane@example.com>
```

The sign-off must use the same e-mail address as the commit author. CI runs
`scripts/ci/check-dco.sh` and rejects pull requests containing commits without
a matching sign-off. To fix the last commit use `git commit --amend -s`; for a
series use `git rebase --signoff master`.

## Licence headers

Every source file starts with an SPDX licence identifier.

Swift files:

```swift
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso
```

Shell, Python and YAML files (after the shebang line, if any):

```sh
# SPDX-License-Identifier: Apache-2.0
```

`scripts/ci/check-spdx.sh` enforces this. Files under `Tests/corpus/fixtures/`
are synthetic diff inputs and are exempt, because they must stay byte-identical.

## Commit messages

Use the form `<area>: <summary>`, for example:

```
diffcore: handle trailing newline at end of file
app: add About window
ci: cache SwiftPM build directory
```

Keep the summary short and in the imperative mood, keep commits small and
focused, and explain the reasoning in the body when it is not obvious.

## Licence of contributions

By contributing, you agree that your contributions are licensed under the
[Apache License, Version 2.0](LICENSE).
