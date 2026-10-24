#!/bin/bash
# Read-only mount, content/signature checks and a disposable drag-copy simulation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:?usage: verify-dmg.sh path/to/image.dmg [--preview|--signed|--distribution]}"
MODE="${2:---distribution}"
case "$MODE" in --preview|--signed|--distribution) ;; *) exit 2 ;; esac
WORK="$(mktemp -d)"
MOUNT="$WORK/mounted"
ATTACHED=0
cleanup() {
    if [ "$ATTACHED" = 1 ]; then
        hdiutil detach "$MOUNT" >/dev/null || { echo "Could not detach $MOUNT; retained $WORK" >&2; return; }
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
hdiutil verify "$DMG"
mkdir "$MOUNT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null
ATTACHED=1
[ -d "$MOUNT/Still.app" ] && [ ! -L "$MOUNT/Still.app" ]
[ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = /Applications ]
[ -f "$MOUNT/.background/background.png" ] && [ -f "$MOUNT/.DS_Store" ]
python3 - "$MOUNT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
allowed = {'Still.app', 'Applications', '.background', '.DS_Store', '.VolumeIcon.icns', '.fseventsd', '.Trashes', '.HFS+ Private Directory Data\r', '.Spotlight-V100'}
extra = {p.name for p in root.iterdir()} - allowed
assert not extra, f'Unexpected DMG items: {extra}'
ds_store = (root / '.DS_Store').read_bytes()
for forbidden in (b'/Users/', b'close-lid-stream', b'.build', b'/var/folders/'):
    assert forbidden not in ds_store and forbidden.decode().encode('utf-16-be') not in ds_store, f'Machine-specific path leaked in .DS_Store: {forbidden!r}'
PY
VERIFY_ARGS=()
[ "$MODE" = --preview ] || VERIFY_ARGS+=("$MODE")
"$ROOT/Scripts/verify-release.sh" "$MOUNT/Still.app" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}
mkdir "$WORK/Applications"
ditto "$MOUNT/Still.app" "$WORK/Applications/Still.app"
"$ROOT/Scripts/verify-release.sh" "$WORK/Applications/Still.app" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}
"$WORK/Applications/Still.app/Contents/MacOS/Still" --smoke
if [ "$MODE" != --preview ]; then
    codesign --verify --strict "$DMG"
    SIGNATURE="$(codesign -dvv "$DMG" 2>&1)"
    printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application: '
    printf '%s\n' "$SIGNATURE" | grep -q '^Timestamp='
    APP_TEAM="$(codesign -dvv "$MOUNT/Still.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    DMG_TEAM="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p')"
    [ -n "$APP_TEAM" ] && [ "$APP_TEAM" = "$DMG_TEAM" ]
fi
if [ "$MODE" = --distribution ]; then
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi
echo "RESULT: DMG structure and disposable installation passed ($MODE)."
echo 'This does not replace a fresh-Mac quarantined download, first launch, or administrator setup test.'
