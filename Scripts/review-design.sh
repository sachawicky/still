#!/bin/bash
# Native component renders or a finite ambient workload. Does not start Still's power policy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/design-review
# macOS Bash 3 has no mapfile. Source paths contain no whitespace in this repository.
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find Sources/StillKit -name '*.swift' -type f | sort)
xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
    "${SOURCES[@]}" Tools/VisualReview.swift -o .build/design-review/StillVisualReview
exec .build/design-review/StillVisualReview "$@"
