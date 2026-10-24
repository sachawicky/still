#!/bin/bash
# One production assembly path for local and release builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/build-release.sh" "$@"
