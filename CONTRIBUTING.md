# Contributing

Thanks for your interest in Still. Bug reports, fixes and small improvements are welcome.

## Before you start

- Open an issue first for anything larger than a fix, so we can agree on scope.
- Still is intentionally small. New features need a clear reason.
- Safety protections (Safety Timeout, battery and thermal limits, restore-on-quit, reconcile-on-launch) must not be weakened.

## Setup

Requires macOS 26 or later and Xcode 27 (Swift 6.2 or later), including Icon Composer and actool.

```bash
swift test
swift run StillCheck          # must report 0 failures
python3 -B Scripts/test-focus-hooks.py
./Scripts/build-release.sh    # builds and audits dist/Still.app
```

## Pull requests

- Keep changes focused and match the surrounding code style.
- Add or update a check in `Sources/StillCheck/main.swift` for any logic change.
- Do not commit build products, credentials or personal data.
- Describe how you tested on real hardware when the change touches sleep behavior.
