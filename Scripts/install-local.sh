#!/bin/bash
# Validate before quitting; retain the previous app until the replacement launches.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source Support/version.env
SRC="$ROOT/dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
STAGE="/Applications/.$APP_NAME.app.installing"
OLD="/Applications/.$APP_NAME.app.previous"
"$ROOT/Scripts/build-release.sh"
[ -d "$SRC" ] || exit 1
# Never delete a recovery bundle from a previous interrupted install.
[ ! -e "$OLD" ] || { echo "Recovery app already exists at $OLD; inspect it before retrying." >&2; exit 1; }
[ ! -e "$STAGE" ] || { echo "Staging app already exists at $STAGE; inspect it before retrying." >&2; exit 1; }
ditto "$SRC" "$STAGE"
"$ROOT/Scripts/verify-release.sh" "$STAGE"
swapped=0
rollback() {
    result=$?
    if [ "$result" -ne 0 ] && [ "$swapped" -eq 1 ] && [ -d "$OLD" ]; then
        echo "Install failed; preparing to restore the previous app." >&2
        if pgrep -x "$APP_NAME" >/dev/null; then
            osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
            for _ in $(seq 1 20); do
                pgrep -x "$APP_NAME" >/dev/null || break
                sleep 0.5
            done
        fi
        if pgrep -x "$APP_NAME" >/dev/null; then
            echo "Still did not quit; recovery app retained at $OLD. Quit before restoring." >&2
        else
            rm -rf "$DEST"
            mv "$OLD" "$DEST"
            open "$DEST" || true
        fi
    fi
    [ ! -d "$STAGE" ] || rm -rf "$STAGE"
    exit "$result"
}
trap rollback EXIT
if pgrep -x "$APP_NAME" >/dev/null; then
    # Request an AppKit quit; never force-kill an awake owner.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.5
    done
    ! pgrep -x "$APP_NAME" >/dev/null || { echo "Quit Still cleanly and retry." >&2; exit 1; }
fi
if [ -e "$DEST" ]; then mv "$DEST" "$OLD"; fi
swapped=1
mv "$STAGE" "$DEST"
open "$DEST"
sleep 3
[ "$(pgrep -x "$APP_NAME" | wc -l | tr -d ' ')" = 1 ] || { echo "Expected exactly one Still process" >&2; exit 1; }
pgrep -fl "^$DEST/Contents/MacOS/$APP_NAME" || exit 1
"$ROOT/Scripts/verify-release.sh" "$DEST"
# Keep rollback artifacts outside the install; no user's preferences are removed.
if [ -d "$OLD" ]; then
    mkdir -p "$ROOT/.build/install-backups"
    mv "$OLD" "$ROOT/.build/install-backups/Still-$(date +%Y%m%d-%H%M%S).app"
fi
trap - EXIT
echo "Installed $VERSION ($BUILD) $RELEASE_CHANNEL at $DEST"
