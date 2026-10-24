# Still 2.0.0 RC 2 — build 7 validation

Source validation on 24 October 2026. Identity: `app.still.macos`, version `2.0.0`, build `7`, channel `rc.2`, macOS 26+, arm64. This record describes engineering checks, not human acceptance or a notarized binary release.

## Product changes

- Still Focus covers selected displays with original Metal ribbons, Midnight/Aurora/Monochrome themes, optional clock, persistent agent attention and adaptive rendering. Automatic/Light/Dark appearance is independent from the ambient theme.
- Shared native menu, settings, welcome and About views; fresh installs leave automatic detection and playback resume off. Migration preserves existing explicit preferences. Local upgrades validate staging and retain a recovery bundle.
- Process-owned `PreventUserIdleSystemSleep` assertions replace global sleep overrides. Kernel and session ceilings are three hours, with an effective battery floor of at least 15%, thermal/Low Power Mode safeguards and explicit resume after sleep or lock.
- External displays release Still's assertion and use macOS clamshell behavior. Legacy Still-owned global flags can be recovered; unrelated flags are reported. The command runner uses explicit `posix_spawn` descriptors and private temporary output files.
- Focus windows close synchronously on a local Escape or background click, remain below the menu bar and permit foreground native banners. Still changes neither macOS Focus modes nor system volume/mute.
- Build 7 adds explicit native-notification opt-in that preserves unknown future preferences, requests alert/sound authorization and reports alert style. Agent attention sounds play once through the selected app sound/volume, independently of banner presentation.

## Repeatable checks

| Check | Coverage |
| --- | --- |
| `swift test` | 36 tests: settings migration, rendering policy, Focus ingress/inbox, targeted notification opt-in, power lifecycle, bounded assertions, process descriptors and legacy rule fixtures |
| `swift run StillCheck` | 146 policy checks: awake, timeout, battery, thermal, legacy reconciliation and playback |
| `python3 -B Scripts/test-focus-hooks.py` | 4 tests in temporary configurations; preservation, idempotence, opt-in routing and safe backups |
| `python3 -B Scripts/test-power-crash.py "$(swift build --show-bin-path)/StillCheck"` | Disposable assertion owner observed in powerd, assertion removed after SIGKILL, global sleep flag unchanged; installed app untouched |
| `Scripts/review-design.sh --verify-focus-lifecycle` | Native windows, local Escape/click, immediate cleanup, display selection, automation inhibit and output-device volume/mute invariance |
| `Scripts/review-design.sh --verify-ambient` | Six appearance/theme GPU renders and four phase-wrap checks |
| `Scripts/build-release.sh` | Optimized build 7, native icon variants, privacy/license resources, ad-hoc Hardened Runtime signature and bundle audit |
| `Scripts/verify-release.sh dist/Still.app` | Bundle version/channel, signature, entitlements, dependencies and absence of development paths/extra executable code |

All checks in the table passed on 24 October 2026: 36 Swift tests, 146 policy checks, 4 Python tests, the disposable crash probe, native Focus lifecycle/audio checks, 10 GPU image checks, and the build 7 release build/bundle audit. Shell syntax, plist lint and whitespace checks also passed. The candidate source tree and image metadata were reviewed for credentials and personal data; local account and diagnostic records were removed before publication. No installation, permission change or real agent-configuration edit is required by this source-publication workflow.

## Known limitations and remaining manual validation

Native idle-sleep assertions cannot guarantee closed-lid work without an external display. No private lid override or per-monitor sleep/wake mechanism is used. Screen-lock observation supplements public session/display events with an undocumented distributed notification; immediate delivery on every macOS version is not guaranteed.

Agent attention depends on the provider emitting a supported hook. Ordinary prose, silent tasks and automatic approval routing are not inferred. Native banners and audible sound depend on authorization, macOS notification settings, Focus modes and output hardware. No global notification setting or third-party permission is changed.

Physical lid close/open, external-display hotplug/mirroring, genuine sleep/lock/reboot, fresh-user permission prompts/revocation, real provider notifications, third-party banners above Focus, audible output, VoiceOver/Full Keyboard Access and sustained battery/thermal use require device testing. Automated policy and window tests do not replace them.

A successful local ad-hoc signature is not Developer ID trust, notarization or App Store acceptance. No sandboxed Store target is provided. See [power safety](POWER-SAFETY.md), [Focus setup](STILL-FOCUS.md), [public binary preparation](PUBLIC-RELEASE.md) and [privacy](PRIVACY.md).
