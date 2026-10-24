#!/bin/bash
# Local packaging only. Does not contact Apple or publish anything.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source Support/version.env
Scripts/verify-release.sh dist/Still.app --distribution
ARCHIVE="dist/Still-$VERSION-$RELEASE_CHANNEL-macOS-arm64.zip"
ditto -c -k --keepParent dist/Still.app "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "Validated local archive: $ARCHIVE"
