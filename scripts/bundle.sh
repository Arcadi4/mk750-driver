#!/usr/bin/env bash
# Build dist/MK750.app from the release product of this Swift package.
# Only generated output under dist/MK750.app is replaced.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
APP_NAME="MK750"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
INFO_PLIST_SOURCE="$ROOT_DIR/Resources/Info.plist"

fail() {
    printf 'bundle: %s\n' "$*" >&2
    exit 1
}

command -v swift >/dev/null 2>&1 || fail "swift was not found on PATH; install the Swift 6 toolchain or Xcode command line tools"
command -v codesign >/dev/null 2>&1 || fail "codesign was not found on PATH"
[[ -f "$INFO_PLIST_SOURCE" ]] || fail "missing $INFO_PLIST_SOURCE"

# Build first, then ask SwiftPM where the release product actually landed.
swift build --configuration release --package-path "$ROOT_DIR"
BIN_DIR="$(swift build --configuration release --package-path "$ROOT_DIR" --show-bin-path | tail -n 1)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
[[ -x "$EXECUTABLE" ]] || fail "release executable not found at $EXECUTABLE"

mkdir -p "$ROOT_DIR/dist"
rm -rf -- "$APP_DIR"
mkdir -p "$MACOS_DIR"
install -m 0755 "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
install -m 0644 "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# Ad-hoc signature: enough for local launching, not for distribution.
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"

printf 'Bundled %s\n' "$APP_DIR"
