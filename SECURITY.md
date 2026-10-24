# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: **Security → Report a vulnerability** on this repository. Do not open a public issue for them.

I aim to respond within a week.

## Privileged surface

New awake sessions use only public, process-owned IOKit idle-sleep assertions. They never enable global `SleepDisabled`, install a helper, or request administrator access. Assertions have a three-hour kernel timeout and are released on process death. App-level safety also observes battery, thermal, Low Power Mode and system events.

Older versions installed `/etc/sudoers.d/still`, granting the user's numeric UID exactly two `pmset -a disablesleep` commands (0 and 1). The new version can clear an old setting only if its ownership marker is present. Unreadable/failed restoration retains that marker and reports a warning; it never claims success or enables the flag again. A one-time administrator recovery is available if the legacy rule is unavailable. Removing the legacy rule remains an explicit user action in Settings.

Native assertions cannot guarantee closed-lid operation without an external display. This override is disabled. Screen-lock detection combines public workspace events with a supplemental, undocumented distributed lock notification; see `Docs/POWER-SAFETY.md` for its limits. No system-wide keyboard tap, notification authorization bypass, or audio-setting change is used.

Privilege escalation, unintended data collection, and failures to release Still-owned resources are in scope.

## Distribution

Official releases will be Developer ID signed, notarized and published with a SHA-256 checksum. Local preview builds (`-LOCAL-PREVIEW`) are ad-hoc signed for local testing only and must not be redistributed. Do not trust binaries from other sources.
