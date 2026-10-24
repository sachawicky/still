#!/bin/bash
# Audits a built Still.app: identity, signature, entitlements, dependencies, paths.
set -euo pipefail
APP="${1:?usage: verify-release.sh path/to/Still.app [--signed|--distribution]}"
DISTRIBUTION="${2:-}"
case "$DISTRIBUTION" in ''|--signed|--distribution) ;; *) echo "Unknown verification mode" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Support/version.env"
BIN="$APP/Contents/MacOS/$APP_NAME"
PLIST="$APP/Contents/Info.plist"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "ok:   $*"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo "<missing>"; }

[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] && ok "bundle id $BUNDLE_ID" || bad "bundle id"
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] && ok "version $VERSION" || bad "version"
[ "$(plist CFBundleVersion)" = "$BUILD" ] && ok "build $BUILD" || bad "build"
[ "$(plist CFBundleExecutable)" = "$APP_NAME" ] && ok "executable" || bad "executable"
[ "$(plist LSUIElement)" = "true" ] && ok "LSUIElement" || bad "LSUIElement"
[ "$(plist LSMinimumSystemVersion)" = "$MIN_MACOS" ] && ok "minimum macOS $MIN_MACOS" || bad "min macOS"
[ -f "$APP/Contents/Resources/Still.icns" ] && [ -f "$APP/Contents/Resources/Assets.car" ] && ok "icon embedded" || bad "icon missing"

ICON_INFO="$(/usr/bin/assetutil --info "$APP/Contents/Resources/Assets.car")"
if printf '%s' "$ICON_INFO" | python3 -c 'import json,sys; a={x.get("Appearance") for x in json.load(sys.stdin) if x.get("AssetType")=="IconImageStack"}; sys.exit(0 if {"NSAppearanceNameAqua","NSAppearanceNameDarkAqua","ISAppearanceTintable"} <= a else 1)'; then
    ok "native light, dark and monochrome/tinted icon stacks"
else bad "missing native icon appearances"; fi

codesign --verify --deep --strict "$APP" 2>&1 && ok "codesign --verify --deep --strict" || bad "codesign verify"
FLAGS="$(codesign -dv "$APP" 2>&1 | grep -E "^CodeDirectory" || true)"
echo "$FLAGS" | grep -q "runtime" && ok "hardened runtime ($FLAGS)" || bad "hardened runtime off ($FLAGS)"
ENT="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
echo "$ENT" | grep -q "com.apple.security.automation.apple-events" && ok "entitlement: apple-events" || bad "entitlement apple-events missing"
echo "$ENT" | grep -q "get-task-allow" && bad "get-task-allow present (blocks notarization)" || ok "no get-task-allow"
echo "$ENT" | grep -q "disable-library-validation\|allow-unsigned-executable-memory\|allow-dyld" && bad "weakening entitlement present" || ok "no runtime-weakening entitlements"

DEPS="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
echo "$DEPS" | grep -v -E '^(/System/Library/|/usr/lib/|@rpath/libswift)' && bad "non-system dependency above" || ok "only system libraries linked"
echo "$DEPS" | grep -i -E "PrivateFrameworks|MediaRemote" && bad "private framework linked" || ok "no private frameworks"
if strings -a "$BIN" | grep -q -E "MediaRemote|PrivateFrameworks|dlopen"; then bad "private-API strings in binary"; else ok "no private-API strings"; fi
if strings -a "$BIN" | grep -E "/Users/|\.build/|close-lid-stream" | head -3 | grep -q .; then
    bad "absolute development paths in binary:"; strings -a "$BIN" | grep -E "/Users/|\.build/|close-lid-stream" | head -3
else ok "no development paths in binary"; fi
EXTRA="$(find "$APP" -type f \( -perm -u+x -o -name '*.sh' \) ! -path "$BIN" | head)"
[ -z "$EXTRA" ] && ok "no stray executables/scripts" || bad "stray executables: $EXTRA"
NESTED="$(find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) | head -3)"
[ -z "$NESTED" ] && ok "no nested code to sign" || bad "nested code present: $NESTED"
plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy" && ok "privacy manifest" || bad "privacy manifest missing/invalid"
[ -f "$APP/Contents/Resources/LICENSE.txt" ] && ok "license" || bad "license missing"
[ "$(plist StillReleaseChannel)" = "$RELEASE_CHANNEL" ] && ok "channel $RELEASE_CHANNEL" || bad "channel"
echo "$ENT" | grep -q "com.apple.security.app-sandbox" && bad "unexpected sandbox entitlement in direct build" || ok "direct distribution: no App Sandbox claim"
lipo -archs "$BIN" | sed 's/^/ok:   architectures: /'

SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
IDENT="$(printf '%s\n' "$SIGNATURE" | grep -E '^Authority=Developer ID Application: ' || true)"
if [ -n "$IDENT" ]; then ok "signed with Developer ID"; else echo "note: ad-hoc signature (no Developer ID): NOT notarizable"; fi
if [ "$DISTRIBUTION" = "--signed" ] || [ "$DISTRIBUTION" = "--distribution" ]; then
    [ -n "$IDENT" ] || bad "Developer ID is required for distribution"
    printf '%s\n' "$SIGNATURE" | grep -q '^Timestamp=' && ok "secure timestamp" || bad "secure timestamp missing"
    printf '%s\n' "$SIGNATURE" | grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' && ok "signing team" || bad "signing team missing"
fi
if [ "$DISTRIBUTION" = "--distribution" ]; then
    xcrun stapler validate "$APP" && ok "stapled notarization ticket" || bad "notarization ticket missing"
    spctl --assess --type execute -vv "$APP" && ok "Gatekeeper assessment" || bad "Gatekeeper rejected"
    syspolicy_check distribution "$APP" && ok "system distribution policy" || bad "system distribution policy rejected"
fi
[ $fail -eq 0 ] && echo "RESULT: bundle checks passed" || { echo "RESULT: FAILED"; exit 1; }
