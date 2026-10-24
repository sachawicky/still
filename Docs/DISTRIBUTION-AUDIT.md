# Still 2.0.0 RC 2 — build 7 distribution scope

The supported build workflow targets native, unsandboxed direct distribution on macOS 26+, Apple silicon. No sandboxed Mac App Store target or Store acceptance is claimed. Hardened Runtime and App Sandbox are distinct mechanisms. A successful ad-hoc build is local test evidence, not a notarized public installer.

Build 7 replaces the old system-wide awake override with public process-owned idle-sleep assertions. It no longer installs a sudoers rule or enables `SleepDisabled` for sessions. Legacy recovery/removal remains an explicit administrator operation. Earlier distribution findings based on global overrides do not describe current sessions.

| Capability | Build 7 behavior | Distribution / compatibility limits |
| --- | --- | --- |
| Awake session | `PreventUserIdleSystemSleep` with a three-hour kernel timeout | Idle sleep only; physical lid and explicit system sleep remain controlled by macOS |
| External display | Release Still's assertion and defer to native clamshell behavior | Hardware/power/OS conditions require device testing |
| Battery, thermal and Low Power Mode | At least 15% battery floor and conservative suspension | Sustained real-device behavior remains a manual check |
| Legacy global sleep setting | Recover only Still-owned state; report unrelated state | Interactive recovery/removal can require administrator consent; no new privileged helper |
| Agent activity | Optional FSEvents under agent session directories; no transcript parsing | Arbitrary home-directory access is not a validated sandbox implementation |
| Agent attention hooks | Explicit opt-in external executable and local Application Support inbox | Provider/version coverage and trust review required; sandbox IPC not designed or certified |
| Playback resume | Optional media key, controlled by Accessibility consent | Cross-application behavior needs hardware/OS validation; consent does not establish sandbox compatibility |
| Focus windows and Metal | Selected display covers, adaptive animation, local Escape/click exit | No lock-screen, capture barrier, per-monitor power-off or universal automation detection |
| Notifications and login item | UserNotifications / SMAppService, explicit opt-in and status | User authorization and macOS settings control actual behavior |
| Lock observation | Public workspace events plus supplemental distributed lock notification | Immediate lock notification is undocumented and requires device testing |
| Binary distribution | Developer ID, secure timestamp, notarization, stapling and policy checks required | No build 7 notarized installer is claimed by source publication |

A future Store variant needs an explicit product scope, App Sandbox design, empirical tests and review against Apple's then-current requirements. No entitlement workaround or review guarantee is provided. See [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

See [public binary preparation](PUBLIC-RELEASE.md) for separate signing/upload gates, [power safety](POWER-SAFETY.md) for API limits and [privacy](PRIVACY.md) for local data use. Fresh-machine permissions, physical lid/display transitions, real notifications and accessibility interaction remain manual release checks.
