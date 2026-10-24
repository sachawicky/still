# Still 1.2.0 · historical design and validation

See [build 7 validation](RELEASE-CANDIDATE.md) for current behavior. The historical click-through, fade and global power-policy descriptions below have been superseded by immediate click/Escape exit and native sleep assertions.

18 October 2026. Agent-attested implementation and checks; human acceptance and hardware testing remain separate.

## Design

The menu stays 320 points wide with a 22-point inset. System type, a quiet blue accent,
semantic foregrounds, 18-point attention surfaces, restrained section spacing and shared
spring timing form the design system in `Views/DesignSystem.swift`. The original seam/ring
mark and Still name remain. Materials are reserved for controls and requests. Native
Liquid Glass uses the installed SDK's supported APIs; Reduce Transparency uses an opaque
semantic surface instead. Reduce Motion removes decorative transitions.

Redesigned surfaces: menu status, session controls and timeout picker, battery/safety
line, restoration warnings, administrator onboarding, persistent agent requests, Focus
activation, settings navigation, display selection/empty state, playback permission
onboarding, login approval state and access removal confirmation. Settings are grouped
into Session, Focus and General within the same compact menu utility. System controls
retain keyboard and VoiceOver semantics; symbols do not replace textual safety states.

## Ambient engine

Historical build 3 description below. Build 4 replaces this mesh with the
[cinematic Metal renderer](AMBIENT-RENDERING.md); the native UI remains unchanged.

`Focus/Ambient.swift` uses one native SwiftUI 4×4 MeshGradient per cover. Four interior
control points drift with independent slow periods; fixed edges prevent gaps and folds.
The colors also evolve continuously. Themes are Midnight (blue/violet), Aurora
(teal/atmospheric violet) and Monochrome (graphite/silver). No external assets, frameworks,
custom shader compilation or display-sized blur buffers are needed. Native backing
handles pixel density and resize. The centered wordmark drifts slightly; the optional
clock sits above it. Attention enters below it without moving the central composition.

Target cadence is 30 fps on AC with nominal temperature, 12 fps on battery, Low Power
Mode or fair temperature, and static with motion disabled, Reduce Motion, serious or
critical temperature. This deliberately avoids a 60 fps budget for very slow movement.
Closing/detaching a cover releases its hosting view. Hidden covers have no timeline;
system/display sleep suspend rendering separately and wake resumes only after both
conditions clear. Safety and GUI-inhibit stops remove the cover immediately; voluntary
exits have a short fade unless Reduce Motion is enabled.

Settings retain the v1 storage key and explicitly decode missing fields, preserving
previous choices when `theme` is added. Unknown themes fall back to Midnight. No changes
to sudoers, privileged setup, session policy or agent hook configuration were made by
this redesign. Existing Codex event-routing/trust limitations still apply; no silence
heuristics or automatic approvals were added. Notification Center requests now expose
Return to agent and Dismiss actions, in addition to the persistent glass menu queue.
The click-through Focus cover continues to direct mouse actions to the Still menu.

## Toolchain and automated checks

- Actual installed tools: Xcode 27.0 (27A266a), macOS SDK 27.0, Swift 6.4.
- Deployment remains macOS 26.0, arm64, bundle identifier `app.still.macos`.
- `swift test`: 12 tests passed. Four new ambient tests cover scheduler states, a
  week of sampled mesh geometry, v1 preference migration and unknown-theme fallback.
- `swift run StillCheck`: 146 checks passed. Power, session and presentation checks
  remain intact; no privileged setup was executed.
- `python3 Scripts/test-focus-hooks.py`: 4 tests passed.
- Release bundle audit: version 1.2.0, build 3, hardened runtime/ad-hoc signature,
  expected entitlements, system dependencies only, no private frameworks or extra scripts.
## Visual review

`Scripts/review-design.sh --render .build/design-review/native-renders` compiles the
actual StillKit components at `-O` into a separate developer harness. It renders only
its own offscreen view tree through NSHostingView, including native switch controls.
The harness is never bundled in Still.app and its profiling mode has no power controller.
Three palette renders plus Focus settings and status/attention compositions in light
and dark were inspected. This caught truncated help text and inconsistent switch
alignment; both were corrected. The volume slider's visible redundant label was removed
while preserving its accessibility label.

These are component renders, not screenshots of the installed menu or a complete
fullscreen session. Native glass compositing is not reliably represented in offscreen
captures. Interactive navigation, live glass appearance and physical motion quality
still require on-device review. Developer previews capture app-owned content only.

## Profiling observations, not performance guarantees

- Instruments Time Profiler: 10-second recording of installed Still at idle, exported
  17 CPU sample rows. A separate `ps` observation read 0.0% CPU and 83,168 KiB RSS.
- Optimized native ambient workload, requested window 1920×1080 points at 30 fps:
  ten one-second `ps` observations ranged 1.3–7.1% CPU, arithmetic mean 3.94%, RSS
  85,808–85,872 KiB.
- Requested window 3840×2160 points at 12 fps: ten observations ranged 0.9–5.8% CPU,
  arithmetic mean 3.92%, RSS 85,664–85,760 KiB.
- These are short process observations on the local Apple Silicon host with other
  work running, not a controlled benchmark. The initial runs did not log actual backing
  dimensions; do not interpret the requested point sizes as verified physical 4K output.
- An eight-second Metal System Trace succeeded; its export contains 206 GPU interval
  rows attributed to the ambient harness. Other apps also appear in that trace. No
  aggregate GPU-utilization percentage, measured delivered fps, battery-life figure or
  leak-free long-session claim is made.
- Raw traces are excluded from Git because Instruments can include host metadata.

Reproduce a finite 35-second workload with
`Scripts/review-design.sh --profile 30 1920 1080` or `--profile 12 3840 2160`.
The harness now logs actual view dimensions/backing scale after layout. Profile with
Instruments rather than extrapolating the observations above.

## Required manual validation

- Installed menu and all settings: keyboard traversal, VoiceOver, light/dark, Increase
  Contrast, Reduce Transparency and Reduce Motion, plus live notification glass.
- Physical Retina/BenQ and multi-display resize/hotplug, Spaces and screen lock.
- Real sleep/wake ordering, closed-lid media playback and automatic session recovery.
- Real Claude/Codex prompts, configured audible sound, optional native notification
  authorization and Return/Dismiss actions. Codex hook trust remains user-managed.
- Foreground automation against an active cover, safe immediate stop, then manual resume.
- Sustained 4K/multi-display GPU/energy and hours-long lifecycle/leak measurement.
