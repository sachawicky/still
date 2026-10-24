#!/bin/bash
# Local only: no notarization submission or publication. Public mode requires Developer ID.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source Support/version.env
MODE="${1:---signed}"
case "$MODE" in --preview|--signed) ;; *) echo 'usage: build-dmg.sh [--signed|--preview]' >&2; exit 2 ;; esac
APP="$ROOT/dist/$APP_NAME.app"
SUFFIX=""
if [ "$MODE" = --preview ]; then
    Scripts/verify-release.sh "$APP"
    SUFFIX="-LOCAL-PREVIEW"
else
    : "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a Developer ID Application identity}"
    Scripts/verify-release.sh "$APP" --signed
    AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    [ "$AUTHORITY" = "$SIGN_IDENTITY" ] || { echo 'App and DMG signing identities must match.' >&2; exit 1; }
fi
DMG="$ROOT/dist/Still-$VERSION-$RELEASE_CHANNEL-macOS-arm64$SUFFIX.dmg"
[ ! -e "$DMG" ] || { echo "Output exists; preserve or remove it explicitly: $DMG" >&2; exit 1; }
VOLNAME="Still $VERSION"
MOUNT="/Volumes/$VOLNAME"
[ ! -e "$MOUNT" ] || { echo "Volume already mounted at $MOUNT; eject it first." >&2; exit 1; }
WORK="$(mktemp -d /private/tmp/still.XXXXXXXX)"
ATTACHED=0
cleanup() {
    if [ "$ATTACHED" = 1 ]; then
        hdiutil detach "$MOUNT" >/dev/null || { echo "Could not detach $MOUNT; working files retained." >&2; return; }
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
hdiutil create -size 48m -fs HFS+ -volname "$VOLNAME" -type UDIF "$WORK/layout.dmg" >/dev/null
hdiutil attach -readwrite -noverify -noautoopen "$WORK/layout.dmg" >/dev/null
ATTACHED=1
ditto "$APP" "$MOUNT/Still.app"
ln -s /Applications "$MOUNT/Applications"
mkdir "$MOUNT/.background"
ART_ARGS=()
[ "$MODE" != --preview ] || ART_ARGS+=(--preview)
swift Tools/DMGArtwork.swift "$MOUNT/.background/background.png" ${ART_ARGS[@]+"${ART_ARGS[@]}"}
cp "$APP/Contents/Resources/Still.icns" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
# Finder writes the standard .DS_Store background and icon positions; no app is launched.
osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set diskFolder to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/background.png") as alias
    tell application "Finder"
        open diskFolder
        set w to container window of diskFolder
        set current view of w to icon view
        set toolbar visible of w to false
        set statusbar visible of w to false
        set bounds of w to {160, 120, 880, 560}
        set options to icon view options of w
        set arrangement of options to not arranged
        set icon size of options to 112
        set text size of options to 13
        set background picture of options to backgroundFile
        set position of item "Still.app" of diskFolder to {180, 220}
        set position of item "Applications" of diskFolder to {540, 220}
        update diskFolder without registering applications
        delay 2
        close w
    end tell
end run
APPLESCRIPT
[ -f "$MOUNT/.DS_Store" ] || { echo 'Finder layout was not saved.' >&2; exit 1; }
sync
hdiutil detach "$MOUNT" >/dev/null
ATTACHED=0
hdiutil convert "$WORK/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK/final.dmg" >/dev/null
if [ "$MODE" = --signed ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$WORK/final.dmg"
    codesign --verify --strict "$WORK/final.dmg"
fi
mv "$WORK/final.dmg" "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Created: $DMG"
echo 'Not submitted to Apple. Recompute checksum after stapling.'
