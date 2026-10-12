#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Builds, checks and publishes a Prism release: a zipped, ad-hoc-signed
# Prism.app (with the prism command inside) on GitHub Releases (decision D7: no
# notarization, DMG, cask or updater). The single place for the whole
# process, run the same way locally and by the CI `release` job.
#
#   scripts/release.sh [--dry-run]
#
# The version is the content of the VERSION file (SemVer; a pre-release such
# as 1.1.0-rc1 is published as a GitHub pre-release). The build number is
# PRISM_BUILD_NUMBER (default 1; CI passes github.run_number).
#
# Steps:
#   a. Preflight: required tools (swift, codesign, ditto, shasum, git, plutil,
#      and gh unless --dry-run), macOS on arm64, a clean working tree,
#      VERSION is SemVer, CHANGELOG.md has a dated "## [<VERSION>] - <date>"
#      section, tag v<VERSION> exists neither locally nor on origin (with
#      --dry-run the origin check is skipped when origin is unreachable).
#   b. Clean build: removes .build, build and dist, then
#      scripts/ci/build-strict.sh (release build with zero warnings, all tests).
#   c. Guards: check-spdx, check-cleanroom, cleanroom-audit (its asset part
#      runs only when PRISM_REFERENCE_SCREENS is set), and the headless
#      acceptance scripts M01, M02, M05 to M10 with CI=true.
#   d. Bundle: scripts/bundle.sh (ad-hoc signature, hardened runtime), then
#      codesign --verify --deep --strict, and every version string must equal
#      VERSION (Info.plist, About via `Prism --version`, `prism --version`).
#   e. Package into dist/: Prism-<VERSION>-macos-arm64.zip,
#      SHA256SUMS and release-notes.md (the CHANGELOG section, with its
#      "Unverified on screen" caveats). File mtimes are set to the commit
#      time (SOURCE_DATE_EPOCH, from `git log -1 --format=%ct`) before zipping.
#   f. Publish (skipped with --dry-run): annotated tag v<VERSION> on HEAD,
#      `git push origin v<VERSION>` (that tag only), then
#      `gh release create` with dist/*, published (not a draft), marked
#      --prerelease when VERSION has a pre-release suffix.
#
# Local iteration only (refused without --dry-run; CI never sets them):
#   PRISM_RELEASE_SKIP_CLEAN=1    keep .build (incremental build)
#   PRISM_RELEASE_SKIP_TESTS=1    skip build-strict.sh (bundle.sh still builds)
#   PRISM_RELEASE_SKIP_ACCEPT=1   skip the acceptance scripts
# Passed through: PRISM_PERF_SCALE (acceptance perf budgets),
#   PRISM_REFERENCE_SCREENS (clean-room asset audit), SOURCE_DATE_EPOCH.
#
# Exit status: 0 on success, 1 on any failure, 2 on a usage error.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

# shellcheck source=lib/semver.sh
source scripts/lib/semver.sh

readonly APP=build/Prism.app
readonly DIST=dist
# On CI (PRISM_CI_SKIP_APP_TESTS=1) only the acceptance scripts that run no
# AppKit app tests; the others run in full on a developer machine.
if [[ "${PRISM_CI_SKIP_APP_TESTS:-}" == "1" ]]; then
    readonly ACCEPT_SCRIPTS=(M01 M02)
else
    readonly ACCEPT_SCRIPTS=(M01 M02 M05 M06 M07 M08 M09 M10)
fi

step() { printf '\n==== release [%s] %s ====\n' "$1" "$2" >&2; }
log() { echo "release: $*" >&2; }
die() { echo "release: error: $*" >&2; exit 1; }
usage() { echo "usage: scripts/release.sh [--dry-run]" >&2; exit 2; }

DRY_RUN=0
case $# in
    0) ;;
    1) [[ "$1" == --dry-run ]] || usage; DRY_RUN=1 ;;
    *) usage ;;
esac
readonly DRY_RUN

skip_flags=()
for flag in PRISM_RELEASE_SKIP_CLEAN PRISM_RELEASE_SKIP_TESTS PRISM_RELEASE_SKIP_ACCEPT; do
    [[ "${!flag:-}" == 1 ]] && skip_flags+=("$flag")
done
if (( ${#skip_flags[@]} > 0 )); then
    (( DRY_RUN )) || die "${skip_flags[*]} may be used only with --dry-run"
    log "WARNING: ${skip_flags[*]} set: this dry run skips checks a release runs"
fi
skipping() { [[ "${!1:-}" == 1 ]]; }

# --- a. Preflight -------------------------------------------------------------
step a "preflight"

tools=(swift codesign ditto shasum git plutil)
(( DRY_RUN )) || tools+=(gh)
for tool in "${tools[@]}"; do
    command -v "$tool" > /dev/null || die "required tool '$tool' not found on PATH"
done
log "ok: tools: ${tools[*]}"

[[ "$(uname -s)" == Darwin ]] || die "releases are built on macOS, not $(uname -s)"
[[ "$(uname -m)" == arm64 ]] || die "releases are built on arm64 (Apple silicon), not $(uname -m)"
log "ok: macOS $(sw_vers -productVersion) on arm64"

dirty=$(git status --porcelain --untracked-files=all)
[[ -z "$dirty" ]] || die "the working tree is not clean; commit or stash first:"$'\n'"$dirty"
log "ok: clean working tree at $(git rev-parse --short HEAD)"

[[ -f VERSION ]] || die "missing VERSION file"
VERSION=$(tr -d '[:space:]' < VERSION)
is_semver "$VERSION" || die "VERSION holds '$VERSION', which is not a SemVer version (e.g. 1.0.0 or 1.1.0-rc1)"
[[ "$(cat VERSION)" == "$VERSION" ]] || die "VERSION must hold the version and a newline only"
PRERELEASE=0
[[ "${VERSION%%+*}" == *-* ]] && PRERELEASE=1
BUILD="${PRISM_BUILD_NUMBER:-1}"
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "PRISM_BUILD_NUMBER '$BUILD' is not numeric"
export PRISM_BUILD_NUMBER="$BUILD"
readonly VERSION BUILD PRERELEASE TAG="v$VERSION"
log "ok: version $VERSION, build $BUILD$( (( PRERELEASE )) && echo ', pre-release')"

heading=$(grep -F -- "## [$VERSION]" CHANGELOG.md | head -n 1 || true)
[[ -n "$heading" ]] || die "CHANGELOG.md has no '## [$VERSION] - <date>' section"
if grep -Eiq 'unreleased|draft' <<<"$heading"; then
    die "CHANGELOG.md section is still a draft: '$heading'; give it a date"
fi
[[ "$heading" =~ ^"## ["[^]]+"] - "[0-9]{4}-[0-9]{2}-[0-9]{2}($|[[:space:]]) ]] \
    || die "CHANGELOG.md heading '$heading' must read '## [$VERSION] - YYYY-MM-DD'"
log "ok: CHANGELOG.md: $heading"

git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && die "tag $TAG already exists locally"
if remote_tags=$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null); then
    [[ -z "$remote_tags" ]] || die "tag $TAG already exists on origin"
    log "ok: tag $TAG is new (local and origin)"
elif (( DRY_RUN )); then
    log "notice: origin is not reachable; remote tag check skipped (dry run)"
else
    die "cannot list the tags of origin (git ls-remote --tags origin)"
fi
if (( ! DRY_RUN )); then
    git var GIT_COMMITTER_IDENT > /dev/null 2>&1 \
        || die "git has no committer identity for the tag (set user.name/user.email or GIT_COMMITTER_NAME/EMAIL)"
fi

swift --version >&2

# --- b. Clean build, zero warnings, all tests -----------------------------------
step b "clean build and tests"
if skipping PRISM_RELEASE_SKIP_CLEAN; then
    rm -rf build "$DIST"
    log "PRISM_RELEASE_SKIP_CLEAN=1: kept .build"
else
    rm -rf .build build "$DIST"
fi
if skipping PRISM_RELEASE_SKIP_TESTS; then
    log "PRISM_RELEASE_SKIP_TESTS=1: build-strict.sh skipped"
else
    scripts/ci/build-strict.sh >&2 || die "strict build or tests failed (logs in build/logs)"
fi

# --- c. Guards and headless acceptance --------------------------------------------
step c "guards and acceptance"
scripts/ci/check-spdx.sh >&2 || die "check-spdx.sh failed"
scripts/ci/check-cleanroom.sh >&2 || die "check-cleanroom.sh failed"
scripts/ci/cleanroom-audit.sh >&2 || die "cleanroom-audit.sh failed"
if skipping PRISM_RELEASE_SKIP_ACCEPT; then
    log "PRISM_RELEASE_SKIP_ACCEPT=1: acceptance scripts skipped"
else
    for m in "${ACCEPT_SCRIPTS[@]}"; do
        log "acceptance $m (headless)"
        # build-strict.sh already ran; never drive or launch the app.
        CI=true PRISM_ACCEPT_HEADLESS=1 PRISM_ACCEPT_NO_APP=1 PRISM_ACCEPT_SKIP_BUILD=1 \
            "scripts/accept/$m.sh" >&2 || die "acceptance $m failed (output in build/accept/$m)"
    done
fi

# --- d. Bundle, signature and versions ------------------------------------------
step d "bundle and verify"
scripts/bundle.sh > /dev/null
codesign --verify --deep --strict --verbose=2 "$APP" >&2 || die "$APP does not verify"
for code in "$APP" "$APP"/Contents/Helpers/*; do
    details=$(codesign -dv "$code" 2>&1)
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"$details" \
        || die "$code is not signed with the hardened runtime"
    grep -q '^Signature=adhoc' <<<"$details" || die "$code is not ad-hoc signed"
done
log "ok: ad-hoc signed with the hardened runtime"
expect_equal() {   # expect_equal <label> <actual> <expected>
    [[ "$2" == "$3" ]] || die "$1: '$2', expected '$3'"
    log "ok: $1 = $2"
}
plist="$APP/Contents/Info.plist"
expect_equal "CFBundleShortVersionString" "$(plutil -extract CFBundleShortVersionString raw "$plist")" "$VERSION"
expect_equal "CFBundleVersion" "$(plutil -extract CFBundleVersion raw "$plist")" "$BUILD"
# Prints the About line and exits before any window or run loop exists.
expect_equal "About (Prism --version)" "$("$APP/Contents/MacOS/Prism" --version)" "Prism $VERSION ($BUILD)"
expect_equal "prism --version" "$("$APP/Contents/Helpers/prism" --version)" "$VERSION"
expect_equal "prism --short-version" "$("$APP/Contents/Helpers/prism" --short-version)" "$VERSION ($BUILD)"

# --- e. Package -------------------------------------------------------------
step e "package"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
export SOURCE_DATE_EPOCH
stamp=$(date -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)
log "file times: $(date -u -r "$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ') (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
# set_times <path>: every file and directory under it gets the commit time.
set_times() { find "$1" -exec touch -h -t "$stamp" {} +; }
# No resource forks, extended attributes, quarantine or ACLs in the archives.
zip_dir() { ditto -c -k --norsrc --noextattr --noqtn --noacl "$@"; }

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="Prism-$VERSION-macos-arm64.zip"
set_times "$APP"
zip_dir --keepParent "$APP" "$DIST/$ZIP"

check_dir=$(mktemp -d "${TMPDIR:-/tmp}/prism-release.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
ditto -x -k "$DIST/$ZIP" "$check_dir"
codesign --verify --deep --strict "$check_dir/Prism.app" >&2 || die "the zipped Prism.app does not verify"
expect_equal "zipped app version" \
    "$(plutil -extract CFBundleShortVersionString raw "$check_dir/Prism.app/Contents/Info.plist")" "$VERSION"
expect_equal "zipped prism --version" "$("$check_dir/Prism.app/Contents/Helpers/prism" --version)" "$VERSION"

(cd "$DIST" && shasum -a 256 "$ZIP" > SHA256SUMS && shasum -a 256 -c SHA256SUMS --quiet)

# The CHANGELOG section: from its heading to the next "## " heading.
notes=$(awk -v head="## [$VERSION]" '
    index($0, head) == 1 { inside = 1; next }
    inside && /^## / { exit }
    inside { print }' CHANGELOG.md)
[[ -n "${notes//[[:space:]]/}" ]] || die "the CHANGELOG.md section for $VERSION is empty"
grep -qi '^### .*unverified on screen' <<<"$notes" \
    || die "the CHANGELOG.md section for $VERSION has no '### Unverified on screen' caveats"
{
    echo "# Prism $VERSION"
    echo
    if (( PRERELEASE )); then
        echo "Pre-release of Prism ${VERSION%%-*}, for testing before the final release."
        echo
    fi
    # Without maintainer comments, from the first non-blank line.
    printf '%s\n' "$notes" | sed -e '/^<!--/,/-->$/d' | sed -e '/./,$!d'
    cat <<EOF

### Files

- \`$ZIP\`: Prism.app (Apple silicon, macOS 14 or later). Ad-hoc signed
  with the hardened runtime and not notarized.
- \`SHA256SUMS\`: check the downloads with \`shasum -a 256 -c SHA256SUMS\`.

### Installing

1. Unzip \`$ZIP\` and move Prism.app to /Applications.
2. The app is not notarized, so macOS quarantines the download. Clear the
   flag once: \`xattr -dr com.apple.quarantine /Applications/Prism.app\`.
3. To use \`prism\` from a terminal (git difftool and mergetool, editors,
   scripts), choose Prism > Integration… and install the command-line
   tool, or link it yourself:
   \`ln -s /Applications/Prism.app/Contents/Helpers/prism ~/bin/prism\`.

Updates: download new versions from the GitHub Releases page.
EOF
} > "$DIST/release-notes.md"
touch -t "$stamp" "$DIST"/*

log "dist/:"
(cd "$DIST" && ls -l) >&2
sed 's/^/release:   /' "$DIST/SHA256SUMS" >&2

# --- f. Publish ---------------------------------------------------------------
if (( DRY_RUN )); then
    step f "publish: skipped (--dry-run)"
    log "would run: git tag -a $TAG -m 'Prism $VERSION' $(git rev-parse --short HEAD)"
    log "would run: git push origin $TAG"
    log "would run: gh release create $TAG $DIST/* --title 'Prism $VERSION'" \
        "--notes-file $DIST/release-notes.md$( (( PRERELEASE )) && echo ' --prerelease')"
    log "dry run complete: Prism $VERSION (build $BUILD)"
    exit 0
fi

step f "publish $TAG"
git tag -a "$TAG" -m "Prism $VERSION" HEAD
git push origin "refs/tags/$TAG"
gh_args=(--verify-tag --title "Prism $VERSION" --notes-file "$DIST/release-notes.md")
(( PRERELEASE )) && gh_args+=(--prerelease)
gh release create "$TAG" "$DIST"/* "${gh_args[@]}"
log "published Prism $VERSION (build $BUILD) as $TAG"
