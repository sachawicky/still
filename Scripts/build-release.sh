#!/bin/bash
# Deterministic release build: produces dist/Still.app from the repository root.
#
# Signing:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  -> Developer ID + hardened runtime + timestamp
#   unset                                                    -> ad-hoc (local testing only)
# A Developer ID identity found in the keychain is reported but never used implicitly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source Support/version.env

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ENTITLEMENTS="Entitlements/$APP_NAME.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> $APP_NAME $VERSION ($BUILD)"

echo "==> swift build -c release (optimized)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$DIST/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Info.plist"
PLIST="$APP/Contents/Info.plist"
cp Support/Info.plist "$PLIST"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
"$PB" -c "Set :CFBundleName $APP_NAME" "$PLIST"
"$PB" -c "Set :CFBundleDisplayName $APP_NAME" "$PLIST"
"$PB" -c "Set :CFBundleExecutable $APP_NAME" "$PLIST"
"$PB" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
"$PB" -c "Set :CFBundleVersion $BUILD" "$PLIST"
"$PB" -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$PLIST"
plutil -lint "$PLIST" >/dev/null

echo "==> app icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/$APP_NAME" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing ($([ "$SIGN_IDENTITY" = "-" ] && echo "ad-hoc" || echo "$SIGN_IDENTITY"))"
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" = "-" ] || SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"

echo "==> verify"
"$ROOT/Scripts/verify-release.sh" "$APP"

echo "==> done: $APP"
