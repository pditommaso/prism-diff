#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Acceptance script for milestone M0 (foundations: repo, packages, build
# and CI). Exit status: 0 when every check passes, 1 otherwise.
#
#   scripts/accept/M00.sh             local run; GUI mode when Accessibility
#                                     is granted (closes the launch window,
#                                     opens About through the menus, closes
#                                     it with Cmd-W)
#   CI=true scripts/accept/M00.sh     headless mode (checks the window list)
#
# Environment:
#   PRISM_ACCEPT_SKIP_BUILD=1   skip scripts/ci/build-strict.sh (CI runs it
#                               in an earlier job)
#   PRISM_ACCEPT_FULL=1         also regenerate the corpus and compare it
#                               with Tests/corpus/generated.sha256 (slow)
#   PRISM_ACCEPT_HEADLESS=1     force headless mode locally
#   PRISM_DIRTY_ROOT=<dir>      private research workspace; check-cleanroom.sh
#                               then also rejects byte-identical copies of its
#                               notes, screenshots and specs
#
# Mapping of the MILESTONES.md M0 acceptance bullets to sections below:
#   build + test pass locally            -> 5 (build-strict.sh)
#   ... and in CI                        -> not verifiable locally; 3 checks
#                                           that ci.yml runs the same steps
#   LICENSE Apache-2.0, SPDX, DCO active -> 1, 2, 3
#   no reference/ or evidence-spec files -> 2 (check-cleanroom.sh)
#   bundle.sh + open: native arm64, About-> 7, 9 (since M10 a plain launch
#                                           shows the launch window; About
#                                           opens from the Prism menu)
#   helper CLIs print the semver         -> 8
#   M00.sh passes                        -> this script
#   GitHub pre-release m00               -> historical (the m00 tag); releases
#                                           now come from scripts/release.sh
# The About screenshot (build/accept/M00/about.png) is for manual
# structural review only.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ACCEPT_ROOT" || exit 1

accept_init M00

readonly CORPUS=Tests/corpus
readonly HELPERS="$ACCEPT_APP/Contents/Helpers"
# shellcheck source=../lib/semver.sh
source scripts/lib/semver.sh

# The version comes from the VERSION file (Plugins/VersionPlugin compiles it
# into PrismInfo.version).
VERSION="$(tr -d '[:space:]' < VERSION)"
echo "== VERSION: ${VERSION:-<not found>}"

# --- check helpers -----------------------------------------------------------

file_has() {       # file_has <file> <fixed string>...
    local file="$1"; shift
    [[ -f "$file" ]] || { echo "missing: $file"; return 1; }
    local s
    for s in "$@"; do
        grep -Fq -- "$s" "$file" || { echo "$file lacks: $s"; return 1; }
    done
}

files_exist() {
    local f rc=0
    for f in "$@"; do
        [[ -s "$f" ]] || { echo "missing or empty: $f"; rc=1; }
    done
    return "$rc"
}

contributing_ok() {
    file_has CONTRIBUTING.md clean-room || return 1
    grep -Eq 'Signed-off-by|git commit -s' CONTRIBUTING.md \
        || { echo "CONTRIBUTING.md lacks DCO sign-off instructions"; return 1; }
}

dco_check() {
    if git rev-parse -q --verify 'master^{commit}' >/dev/null; then
        scripts/ci/check-dco.sh master..HEAD
    elif git rev-parse -q --verify 'origin/master^{commit}' >/dev/null; then
        echo "notice: no local master, using origin/master..HEAD"
        scripts/ci/check-dco.sh origin/master..HEAD
    else
        # Shallow CI checkouts have no main; the CI guards job checks the
        # event's own range instead.
        echo "notice: no master or origin/master; DCO check skipped here"
    fi
}

ci_references() {
    local wf=.github/workflows/ci.yml
    file_has "$wf" check-dco.sh check-spdx.sh check-cleanroom.sh \
        build-strict.sh build-strict-selftest.sh manifest-selftest.sh \
        scripts/bundle.sh scripts/accept/M00.sh \
        actions/upload-artifact || return 1
    grep -Eq '^[[:space:]]+runs-on:[[:space:]]+macos-26' "$wf" \
        || { echo "$wf: no macos-26 runner"; return 1; }
}

# Prints "<kind> <name> <type>" lines for targets and products.
package_shape() {
    swift package dump-package 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin)
for t in d["targets"]:
    print("target", t["name"], t["type"])
for p in d["products"]:
    print("product", p["name"], next(iter(p["type"])))
'
}

package_ok() {
    local shape m rc=0
    shape="$(package_shape)" || { echo "dump-package failed"; return 1; }
    echo "$shape"
    for m in DiffCore TextImport FolderCore PrismProtocol; do
        grep -qx "target $m regular" <<<"$shape" || { echo "missing library target $m"; rc=1; }
    done
    grep -qx "target PrismClient regular" <<<"$shape" || { echo "missing library target PrismClient"; rc=1; }
    for m in PrismTool PrismApp; do
        grep -qx "target $m executable" <<<"$shape" || { echo "missing executable target $m"; rc=1; }
    done
    for m in DiffCore TextImport FolderCore PrismProtocol PrismClient PrismTool PrismApp; do
        grep -qx "target ${m}Tests test" <<<"$shape" || { echo "missing test target ${m}Tests"; rc=1; }
    done
    grep -qx "product prism executable" <<<"$shape" || { echo "missing executable product prism"; rc=1; }
    return "$rc"
}

diffcore_foundation_free() {
    ! grep -rEn '^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(Foundation|AppKit|Cocoa)' Sources/DiffCore
}

corpus_fixtures_present() {
    files_exist \
        "$CORPUS/fixtures/text/a.swift" "$CORPUS/fixtures/text/b.swift" \
        "$CORPUS/fixtures/text/big_a.txt" "$CORPUS/fixtures/text/big_b.txt" \
        "$CORPUS/fixtures/folders/left/README.md" "$CORPUS/fixtures/folders/right" \
        "$CORPUS/fixtures.sha256"
}

corpus_checksums() {
    (cd "$CORPUS" && shasum -a 256 -c fixtures.sha256 --quiet) || return 1
    # Every committed fixture file must be listed in the manifest.
    local listed actual
    listed=$(awk '{ print $2 }' "$CORPUS/fixtures.sha256" | sort)
    actual=$(cd "$CORPUS" && find fixtures -type f ! -name .DS_Store | sort)
    [[ "$listed" == "$actual" ]] || { echo "manifest and fixtures differ:"; diff <(echo "$listed") <(echo "$actual"); return 1; }
}

make_repo_ok() {
    local tmp rc=0 commits modified
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/home"
    HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$CORPUS/scripts/make-repo.sh" "$tmp/repo" || rc=1
    if (( rc == 0 )); then
        commits=$(GIT_CONFIG_GLOBAL=/dev/null git -C "$tmp/repo" rev-list --all --count)
        modified=$(GIT_CONFIG_GLOBAL=/dev/null git -C "$tmp/repo" status --porcelain | wc -l | tr -d ' ')
        echo "commits=$commits modified=$modified"
        [[ "$commits" == 3 && "$modified" == 2 ]] || rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}

plist_value() {
    plutil -extract "$1" raw -o - "$ACCEPT_APP/Contents/Info.plist"
}

plist_ok() {
    local id name ver
    id=$(plist_value CFBundleIdentifier) || return 1
    name=$(plist_value CFBundleName) || return 1
    ver=$(plist_value CFBundleShortVersionString) || return 1
    echo "id=$id name=$name version=$ver"
    [[ "$id" == "$ACCEPT_BUNDLE_ID" && "$name" == Prism && -n "$VERSION" && "$ver" == "$VERSION" ]]
}

arm64_only() {
    local out
    out=$(file "$1") || return 1
    echo "$out"
    [[ "$out" == *arm64* && "$out" != *x86_64* ]]
}

has_runtime_flag() {
    local out
    out=$(codesign -dv "$1" 2>&1) || { echo "$out"; return 1; }
    grep -E '^CodeDirectory' <<<"$out"
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"$out"
}

prints_version() {  # prints_version <binary>
    local out
    out=$("$1" --version) || return 1
    echo "output: $out"
    is_semver "$out" && [[ "$out" == "$VERSION" ]]
}

# fails_cleanly <status> <label>: the status is a normal failure exit:
# non-zero and not from a signal (>128, e.g. 134 for SIGABRT).
fails_cleanly() {
    echo "$2: exit $1"
    (( $1 != 0 && $1 < 128 ))
}

# survives_closed_output <binary> <args...>: when its output cannot be
# written, the tool reports it with a non-zero exit status of its own
# instead of exiting 0 (output silently lost) or dying from a signal.
#   1. stdout and stderr closed (EBADF).
#   2. stdout is a pipe that is already broken before the tool starts, with
#      SIGPIPE ignored as when git or an IDE launches it (EPIPE). A FIFO is
#      opened read-write (the open never blocks), the write end is opened,
#      then the read end is closed, so no reader is left; the tool is
#      started only afterwards. There is no race between the tool and a
#      reader exiting, unlike `tool | (exec 0<&-)`.
survives_closed_output() {
    local status=0 dir
    "$@" >&- 2>&- || status=$?
    fails_cleanly "$status" "closed stdout/stderr" || return 1

    dir="$(mktemp -d)" || return 1
    mkfifo "$dir/fifo" || { rmdir "$dir"; return 1; }
    status=0
    (
        trap '' PIPE
        # shellcheck disable=SC2094  # both ends of the FIFO, on purpose
        exec 3<>"$dir/fifo" 4>"$dir/fifo" 3<&-
        exec "$@" >&4 2>/dev/null
    ) || status=$?
    unlink "$dir/fifo"; rmdir "$dir"
    fails_cleanly "$status" "broken pipe, SIGPIPE ignored"
}

exits_with() {      # exits_with <status> <command...>
    local want="$1" got=0; shift
    "$@" || got=$?
    echo "exit status $got (want $want)"
    (( got == want ))
}

# launch_window_headless: our app shows exactly one normal-layer window and
# it is the launch window (M10): 400 points wide, 500-540 tall (content plus
# title bar) and, when titles are readable, titled 'Prism'.
launch_window_headless() {
    local lines n title w h
    lines=$(_app_windows | awk -F'\t' '$2 == 0')
    echo "${lines:-<no layer-0 windows>}"
    n=$(grep -c . <<<"$lines")
    (( n == 1 )) || { echo "want exactly 1 layer-0 window, got $n"; return 1; }
    title=$(cut -f5 <<<"$lines")
    IFS=, read -r _ _ w h <<<"$(cut -f3 <<<"$lines")"
    [[ -z "$title" || "$title" == "Prism" ]] || { echo "title '$title'"; return 1; }
    (( w == 400 && h >= 500 && h <= 540 )) || { echo "size ${w}x${h} is not the launch window"; return 1; }
}

cmd_w_closes() {
    local attempt
    for attempt in 1 2 3 4; do
        echo "attempt $attempt"
        app_key 13 cmd || return 1      # key code 13 = "w"
        if wait_until 2 app_window_closed "$1"; then
            return 0
        fi
    done
    echo "window '$1' still open after $attempt Cmd-W presses"
    return 1
}

app_gone() {
    ! app_running
}

# --- 1. repository and legal files ------------------------------------------
echo "-- 1. repository and legal files"
check "inside a git work tree" git rev-parse --is-inside-work-tree
check "LICENSE is the Apache License 2.0" file_has LICENSE \
    'Apache License' 'Version 2.0, January 2004' 'END OF TERMS AND CONDITIONS'
check "NOTICE, README.md, docs/spec-public/README.md present" \
    files_exist NOTICE README.md docs/spec-public/README.md
check "CONTRIBUTING.md has clean-room rule and DCO sign-off" contributing_ok

# --- 2. guards ---------------------------------------------------------------
echo "-- 2. guards"
check "SPDX headers (check-spdx.sh)" scripts/ci/check-spdx.sh
check "SPDX guard self-test (fixture exemption needs a pinned checksum)" bash scripts/tests/spdx-selftest.sh
check "clean-room rules (check-cleanroom.sh)" scripts/ci/check-cleanroom.sh
check "clean-room guard self-test" bash scripts/tests/cleanroom-selftest.sh
check "acceptance helpers self-test" bash scripts/accept/tests/lib-selftest.sh
check "DiffCore imports no Foundation" diffcore_foundation_free
check "DCO sign-off (check-dco.sh)" dco_check

# --- 3. CI wiring -------------------------------------------------------------
echo "-- 3. CI wiring"
check "ci.yml runs guards, build, bundle, M00 and uploads" ci_references

# --- 4. package shape ---------------------------------------------------------
echo "-- 4. package shape"
check "targets, test targets and the prism executable" package_ok

# --- 5. strict build ----------------------------------------------------------
echo "-- 5. strict build"
if [[ "${PRISM_ACCEPT_SKIP_BUILD:-}" == 1 ]]; then
    echo "notice: PRISM_ACCEPT_SKIP_BUILD=1, build-strict.sh skipped"
else
    check "Package.swift plugin path matches the active toolchain" bash scripts/tests/manifest-selftest.sh
    check "release build zero warnings + swift test (build-strict.sh)" scripts/ci/build-strict.sh
    check "build-strict.sh catches warnings behind a warm cache" bash scripts/tests/build-strict-selftest.sh
fi

# --- 6. corpus ------------------------------------------------------------------
echo "-- 6. corpus"
check "corpus fixtures present" corpus_fixtures_present
check "fixtures match fixtures.sha256" corpus_checksums
check "make-repo.sh: 3 commits, 2 modified files" make_repo_ok
if [[ "${PRISM_ACCEPT_FULL:-}" == 1 ]]; then
    check "generate.py --check" /usr/bin/python3 -I "$CORPUS/scripts/generate.py" --check
else
    echo "notice: generate.py --check skipped (set PRISM_ACCEPT_FULL=1)"
fi

# --- 7. bundle --------------------------------------------------------------------
echo "-- 7. bundle"
check "scripts/bundle.sh succeeds" scripts/bundle.sh
check "VERSION is semver" is_semver "$VERSION"
check "shell semver check matches PrismInfo.isSemver" bash scripts/tests/semver-selftest.sh
check "Info.plist: id, name, version == VERSION" plist_ok
check "Contents/MacOS/Prism is arm64 only" arm64_only "$ACCEPT_EXEC"
check "AppIcon.icns present" files_exist "$ACCEPT_APP/Contents/Resources/AppIcon.icns"
check "codesign --verify --deep --strict" codesign --verify --deep --strict --verbose=2 "$ACCEPT_APP"
check "hardened runtime: app" has_runtime_flag "$ACCEPT_APP"
check "hardened runtime: prism helper" has_runtime_flag "$HELPERS/prism"
check "one helper only: Helpers holds just prism" bash -c "[[ \"\$(ls '$HELPERS')\" == prism ]]"
check "release zip build/Prism-$VERSION-macos-arm64.zip" files_exist "$ACCEPT_ROOT/build/Prism-$VERSION-macos-arm64.zip"

# --- 8. helper CLIs ---------------------------------------------------------------
echo "-- 8. helper CLIs"
check "Helpers/prism --version prints $VERSION" prints_version "$HELPERS/prism"
check "prism --bogus (app-integration usage error) exits 1" exits_with 1 "$HELPERS/prism" --bogus
check "prism --help with closed or broken output fails cleanly (non-zero, no signal)" survives_closed_output "$HELPERS/prism" --help

# --- 9. launch -----------------------------------------------------------------------
echo "-- 9. launch"
# app_launch refuses to start when build/Prism.app already runs; that
# instance is not ours to quit, so the launch check then fails instead.
check "open build/Prism.app" app_launch
check "process alive" wait_until 5 app_running
check "runs natively (Arch=ARM64, no Rosetta)" app_is_native
if gui_available; then
    check "launch window 'Prism' shown at launch" app_wait_window "Prism" 10
    check "File menu: Close Window closes it" ax_click_menu File "Close Window"
    check "window 'Prism' closed" wait_until 5 app_window_closed "Prism"
    check "click Prism > About Prism" ax_click_menu Prism "About Prism"
    check "capture About window (manual review)" eval 'app_wait_window "About Prism" 10 && capture about "About Prism"'
    check "window 'About Prism' reappears" app_wait_window "About Prism" 10
    check "Cmd-W closes 'About Prism'" cmd_w_closes "About Prism"
else
    check "the one window shown at launch is the launch window" wait_until 10 launch_window_headless
fi
check "quit Prism.app" app_quit
check "no Prism.app process left" app_gone

accept_summary
