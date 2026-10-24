# Changelog

## 2.0.0 RC 2 — build 7

- Explicit native-notification opt-in command preserves all other and future Focus settings and requests alert/sound authorization.
- Notification diagnostics include alert style; Focus lifecycle validation checks output-device volume/mute invariance.
- Public documentation now covers build 7, current sleep/Focus behavior, notification setup and macOS limitations; local account, diagnostic and backup records are excluded.
- Source Info.plist defaults match the build 7 / rc.2 release identity; local configuration and backup exclusions are expanded.


## 2.0.0 RC 2 — build 6

- Native idle-sleep assertions replace global SleepDisabled; explicit sleep takes priority.
- Three-hour kernel/session ceiling, battery safeguards, lock/sleep release with manual resume, and native external-display handling.
- Process-launch descriptor fix and recovery of legacy owned sleep settings.
- Focus banners in the foreground, immediate local Escape/click exit and synchronous window cleanup.
- Closed-lid operation without an external display is no longer guaranteed; see Docs/POWER-SAFETY.md for API limits, test evidence and rollback.

## 2.0.0 RC 1 — build 5

- Automatic, Light and Dark appearance shared by menus, settings, About and Focus; separate ambient identities.
- Pearl/silver daytime palettes and refined satin ribbon geometry, depth and lighting.
- Native Icon Composer source with original SVG layers and compiled macOS appearance variants.
- Welcome guide, About window, explicit permissions, safer fresh-install defaults and visible notification denial.
- Permission rechecks, renderer/controller cleanup, release identity and privacy disclosures.
- Validated staging and recoverable local upgrades; fail-closed distribution packaging.
- Direct distribution feasibility audit; no claim of App Store compatibility or notarization.


## 1.2.0 (build 4 · local ambient upgrade)

- Original Metal ribbon surfaces with continuous folding, parallax, translucent layers and palette-colored lighting
- Original Midnight, Aurora and Monochrome color anchors preserved
- Display-linked rendering up to 60 fps; 12 fps and reduced pixel budget on battery/Low Power/fair temperature
- Adaptive GPU budget, static accessibility/thermal modes, occlusion pause and drawable release
- App-only 4K render previews, GPU timing and lifecycle review tools

## 1.2.0 (build 3)

- Unified compact menu, session controls, permission onboarding and safety states
- Session, Focus and General settings with native glass controls and semantic appearance
- Generative native mesh backgrounds: Midnight, Aurora and Monochrome
- Adaptive 30/12 fps ambient rendering, static accessibility/thermal fallback and sleep suspension
- Refined persistent agent attention, gentle transitions and native notification actions
- Backward-compatible Focus settings migration; existing power policy and hooks preserved

## 1.1.0 (build 2)

- Still Focus ambient cover for selected displays, clock and restrained motion
- Persistent attention queue, deduplication, configurable sound and optional native notifications
- Passive Claude notification hooks and Codex structured question hooks; optional user-routed permission integration
- Foreground GUI compatibility inhibit with acknowledged local signals
- Existing power protections retained; no private per-display sleep APIs

## 1.0.0 (build 1)

First public release.

- Streaming, AI Work and Manual contexts
- Safari/AirPlay playback recovery
- Claude Code and Codex activity detection
- Safety Timeout, battery, thermal and Low Power Mode safeguards
- Launch at Login, single-instance enforcement, scoped administrator setup
- `still` wordmark in the popover and menu bar (hideable in Settings)
