#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP=".build/app/Still.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Still "$APP/Contents/MacOS/Still"
echo "==> rendering app icon"
ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET"
"$APP/Contents/MacOS/Still" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing (ad-hoc, hardened runtime)"
codesign --force --verbose --options runtime \
    --entitlements Entitlements/Still.entitlements \
    -s - "$APP"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>&1 | tail -8 || true

echo "==> smoke test"
"$APP/Contents/MacOS/Still" --smoke

echo "==> done: $(pwd)/$APP"
