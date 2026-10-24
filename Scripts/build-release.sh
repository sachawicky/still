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

if [ "${REQUIRE_DEVELOPER_ID:-0}" = 1 ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Developer ID signing is required; set SIGN_IDENTITY explicitly." >&2; exit 1
fi
if [ "$SIGN_IDENTITY" != "-" ]; then
    case "$SIGN_IDENTITY" in
        'Developer ID Application: '*) ;;
        *) echo "Use a Developer ID Application identity for direct distribution." >&2; exit 1 ;;
    esac
    security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null || {
        echo "Requested Developer ID identity is not available in the keychain." >&2; exit 1;
    }
fi

echo "==> $APP_NAME $VERSION ($BUILD)"

echo "==> swift build -c release (optimized)"
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=."
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

echo "==> native Icon Composer assets"
TEMP_ASSETS="$(mktemp -d)"
trap 'rm -rf "$TEMP_ASSETS"' EXIT
xcrun actool Art/Icons/Still.icon --compile "$APP/Contents/Resources" \
    --output-partial-info-plist "$TEMP_ASSETS/icon-info.plist" --app-icon Still \
    --enable-icon-stack-fallback-generation YES --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" --target-device mac --output-format human-readable-text
"$PB" -c "Set :CFBundleIconFile Still" "$PLIST"
"$PB" -c "Set :StillReleaseChannel $RELEASE_CHANNEL" "$PLIST"
cp Support/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp Docs/PRIVACY.md "$APP/Contents/Resources/Privacy.txt"

echo "==> signing ($([ "$SIGN_IDENTITY" = "-" ] && echo "ad-hoc" || echo "$SIGN_IDENTITY"))"
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" = "-" ] || SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"

echo "==> verify"
"$ROOT/Scripts/verify-release.sh" "$APP"
if [ "$SIGN_IDENTITY" != "-" ]; then
    "$ROOT/Scripts/verify-release.sh" "$APP" --signed
fi

echo "==> smoke (read only)"
"$APP/Contents/MacOS/$APP_NAME" --smoke
{
    printf 'Still %s (%s) %s\n' "$VERSION" "$BUILD" "$RELEASE_CHANNEL"
    xcodebuild -version
    swift --version
    shasum -a 256 "$APP/Contents/MacOS/$APP_NAME"
} > "$DIST/build-record.txt"
echo "==> done: $APP"
