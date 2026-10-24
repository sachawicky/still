# Still Focus — historical build 2 validation

This records earlier engineering coverage, not the current installed state or human acceptance. See [build 7 validation](RELEASE-CANDIDATE.md) for current commands, results and macOS limits.

## Historical checks

- Eight Focus tests covered hook filtering, explicit approval/question routing, deduplication, multiple requests, dismissal, display selection, settings persistence, durable private inbox handling and target allowlisting.
- The existing StillCheck harness passed 146 policy checks.
- Four Python configuration tests covered merge preservation, idempotence, opt-in approval routing, dry-run behavior, backup permissions, malformed input and symlink rejection in temporary fixtures.
- A local ad-hoc bundle audit covered identity, expected entitlements and system-only dependencies. This did not establish notarization or public binary distribution readiness.
- Compatibility begin/end signals received main-thread acknowledgement. This did not establish full mouse/keyboard automation over a physical display cover.

## Remaining interaction

Physical display coverage/hotplug/lid-close, genuine provider prompt delivery, audible output, native notification delivery, screen lock/Spaces behavior, accessibility and foreground GUI automation require device interaction. Current Focus exit, power-safety and notification behavior supersedes the historical implementation; see [Focus setup](STILL-FOCUS.md) and [power safety](POWER-SAFETY.md).

Local application state, configuration contents, preference values, private event inboxes and backups are omitted from this public record and excluded from Git.
