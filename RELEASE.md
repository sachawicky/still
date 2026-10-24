# Still 2.0.0 RC 2 — build 7 release process

Identity: app.still.macos, version 2.0.0, build 7, channel rc.2. macOS 26+, Apple silicon only. Xcode 27 is the validated toolchain. Support/version.env is the release identity source; build-release.sh applies it to the bundle. Support/Info.plist carries matching defaults. No universal binary is claimed. Build outputs depend on the SDK/toolchain; reproducible procedure does not imply bit-identical signatures or timestamps.

## Validation and local installation

```
swift test
swift run StillCheck
python3 Scripts/test-focus-hooks.py
Scripts/review-design.sh --verify-ambient
Scripts/review-design.sh --verify-focus-lifecycle
Scripts/build-release.sh
Scripts/verify-release.sh dist/Still.app
```

Install locally only when an application replacement is intended, using `Scripts/install-local.sh`. See [build 7 checks and remaining device validation](Docs/RELEASE-CANDIDATE.md).

Builds compile the native Icon Composer source using actool (including fallback ICNS), embed the privacy disclosure and license, strip local symbols and sign with Hardened Runtime. Default signing is ad-hoc. Existing preferences and agent configuration are preserved. New installations start with streaming/agent/playback automation off, a finite session timeout, notification opt-in and no login item. Explicit settings from 1.2 remain intact. The installer validates staging before quitting, verifies launch and retains the previous bundle under .build/install-backups. Failed upgrades restore the old bundle when available.

## Public direct distribution — requires maintainer approval

Read Docs/DISTRIBUTION-AUDIT.md first. No Store build is supported. A valid Developer ID Application certificate and private key must exist in the keychain; never add credentials to the repository. Rebuild with an explicit SIGN_IDENTITY environment variable. The script adds a secure timestamp for that identity. Inspect actual signature authority, TeamIdentifier, entitlements and runtime flags.

Only after explicit approval to upload, the maintainer can create a submission ZIP and submit it with `xcrun notarytool submit` using a previously configured keychain profile. Wait for Accepted, inspect the log, staple using `xcrun stapler staple dist/Still.app`, and validate the ticket. Do not weaken Gatekeeper or remove quarantine to obtain a passing result. `Scripts/package-direct.sh` refuses ad-hoc, unstapled or Gatekeeper-rejected bundles and only creates a local ZIP/checksum; it does not upload or publish.

Source commits and pushes, binary releases, Apple notarization submissions and Store submissions are separate actions. The build 7 source publication does not authorize binary uploads or notarization. No workflow publishes installers automatically. No credentials or signing profiles are stored in CI. Local unsigned CI artifacts must not be advertised as public installers.

## Update and failure behavior

Updates are manual replacements from the verified distribution source. No remote code, updater feed or automatic download is present. A later updater needs signature continuity, authenticated metadata and rollback review. End sessions and quit cleanly before replacing. macOS DiagnosticReports provides crash reporting; Metal failures log via os.Logger and fall back to static gradients. Current sessions use process-owned idle-sleep assertions, released by macOS on process death and bounded by a three-hour kernel timeout. They never enable the global sleep flag. Failed recovery of a Still-owned legacy flag retains a visible warning and its ownership marker. Sleep, lock and session interruptions end Focus and require explicit resume. See Docs/POWER-SAFETY.md for external-display handling and macOS limitations.

## Required human/device release checks

Fresh Mac: consent dialogs, cancel/retry, no session before an explicit action/opt-in, Accessibility and notification revocation, Launch at Login approval, reboot and uninstall. Upgrade from a real 1.2 install: preserve defaults, stable identity and reconciliation; changed ad-hoc signatures may require TCC approval again. Physically close/open the lid, disconnect each external display, sleep/wake, switch power sources and sustain a workload long enough for thermal pressure. Exercise VoiceOver and Full Keyboard Access with system contrast/transparency preferences. No synthetic test substitutes for these checks or App Store acceptance.
