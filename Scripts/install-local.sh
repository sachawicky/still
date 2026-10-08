#!/bin/bash
# Local convenience installer: build release, quit running Still, replace /Applications/Still.app, launch it.
# Fails closed: any error aborts before the existing install is touched, except the final swap.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source Support/version.env

SRC="$ROOT/dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
STAGE="/Applications/.$APP_NAME.app.installing"
OLD="/Applications/.$APP_NAME.app.previous"

"$ROOT/Scripts/build-release.sh"
[ -d "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

echo "==> quitting running $APP_NAME (releases normal sleep on exit)"
if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.5
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "$APP_NAME did not quit cleanly; quit it from its menu and re-run." >&2
        exit 1
    fi
fi

echo "==> installing to $DEST"
[ -n "$STAGE" ] && [ "${STAGE#/Applications/.}" != "$STAGE" ]
rm -rf "$STAGE" "$OLD"
ditto "$SRC" "$STAGE"
codesign --verify --deep --strict "$STAGE"
if [ -e "$DEST" ]; then mv "$DEST" "$OLD"; fi
mv "$STAGE" "$DEST"
rm -rf "$OLD"

echo "==> launching $DEST"
open "$DEST"
sleep 3
RUNNING="$(pgrep -fl "^$DEST/Contents/MacOS/$APP_NAME" || true)"
[ -n "$RUNNING" ] && echo "running: $RUNNING" || { echo "not running from $DEST" >&2; exit 1; }
