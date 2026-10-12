#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Paolo Di Tommaso
#
# Builds the release binaries and assembles build/Prism.app by hand, using
# only the Command Line Tools (swift, plutil, iconutil, codesign, ditto):
#
#   Prism.app/Contents/Info.plist        rendered from Resources/Info.plist.in
#   Prism.app/Contents/MacOS/Prism       the PrismApp executable
#   Prism.app/Contents/Helpers/prism     the CLI: opens files in the app, and
#                                        the headless engine commands
#   Prism.app/Contents/Resources/AppIcon.icns
#
# Everything is signed ad hoc with the hardened runtime, inside out, then the
# bundle is verified and zipped to build/Prism-<version>.zip. The signed
# prism helper is also archived on its own, for use without the app, as
# build/prism-<version>-macos-arm64.zip (a single file named prism).
# The icon is regenerated only when scripts/tools/make-icon.swift changes.
#
# Version: the VERSION file (CFBundleShortVersionString). Build number:
# PRISM_BUILD_NUMBER (CFBundleVersion, default 1; CI passes its run number).
# Plugins/VersionPlugin compiles the same two values into PrismInfo, so the
# About window and `--version` agree with Info.plist; this is checked.
#
# Prints the bundle path on success. Exit status: 0 on success, non-zero
# on any failure.
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# shellcheck source=lib/semver.sh
source scripts/lib/semver.sh

readonly BUNDLE_ID=io.github.pditommaso.prism
readonly BUILD_DIR=build
readonly APP="$BUILD_DIR/Prism.app"
readonly PLIST_TEMPLATE=Resources/Info.plist.in
readonly ICON_SCRIPT=scripts/tools/make-icon.swift
readonly ICNS="$BUILD_DIR/AppIcon.icns"
readonly ICON_STAMP="$BUILD_DIR/AppIcon.sha256"

log() { echo "bundle: $*" >&2; }
die() { echo "bundle: error: $*" >&2; exit 1; }

[[ -f VERSION ]] || die "missing VERSION file"
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD="${PRISM_BUILD_NUMBER:-1}"
is_semver "$VERSION" || die "VERSION '$VERSION' is not semver"
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "PRISM_BUILD_NUMBER '$BUILD' is not numeric"
export PRISM_BUILD_NUMBER="$BUILD"
readonly VERSION BUILD
readonly ZIP="$BUILD_DIR/Prism-$VERSION.zip"
readonly CLI_ZIP="$BUILD_DIR/prism-$VERSION-macos-arm64.zip"

# 1. Release binaries.
log "building release binaries ($VERSION, build $BUILD)"
swift build -c release >&2
BIN=$(swift build -c release --show-bin-path)
for exe in PrismApp prism; do
    [[ -x "$BIN/$exe" ]] || die "missing build product $BIN/$exe"
done
built=$("$BIN/prism" --short-version)
[[ "$built" == "$VERSION ($BUILD)" ]] || die "built prism reports '$built', expected '$VERSION ($BUILD)'"

# 2. Icon, cached on the hash of the drawing script.
mkdir -p "$BUILD_DIR"
icon_hash=$(shasum -a 256 "$ICON_SCRIPT" | cut -d' ' -f1)
if [[ -f "$ICNS" && -f "$ICON_STAMP" && "$(cat "$ICON_STAMP")" == "$icon_hash" ]]; then
    log "icon is up to date"
else
    log "rendering app icon"
    iconset="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$iconset"
    swift "$ICON_SCRIPT" "$iconset" >/dev/null
    iconutil -c icns "$iconset" -o "$ICNS"
    rm -rf "$iconset"
    printf '%s\n' "$icon_hash" > "$ICON_STAMP"
fi

# 3. Bundle layout.
log "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/PrismApp" "$APP/Contents/MacOS/Prism"
cp "$BIN/prism" "$APP/Contents/Helpers/prism"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD/g" "$PLIST_TEMPLATE" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >&2
if grep -q '@[A-Z]*@' "$APP/Contents/Info.plist"; then
    die "unrendered placeholder left in Info.plist"
fi

# 4. Ad-hoc signing with the hardened runtime, innermost code first.
sign() {
    codesign --force --sign - --options runtime --timestamp=none "$@" >&2
}
log "signing"
sign --identifier "$BUNDLE_ID.tool" "$APP/Contents/Helpers/prism"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" >&2

# 5. Release archive.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
log "wrote $ZIP"

# 6. Standalone CLI archive: the signed helper, alone at the top level.
cli_stage="$BUILD_DIR/cli-stage"
rm -rf "$cli_stage" "$CLI_ZIP"
mkdir -p "$cli_stage"
cp -p "$APP/Contents/Helpers/prism" "$cli_stage/prism"
ditto -c -k "$cli_stage" "$CLI_ZIP"
rm -rf "$cli_stage"
log "wrote $CLI_ZIP"

echo "$APP"
