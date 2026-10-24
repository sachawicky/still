# Cinematic ambient rendering · historical build 4

See [build 7 validation](RELEASE-CANDIDATE.md) for current checks and limitations.

18 October 2026. Agent-attested implementation and measurements; physical display
acceptance remains a separate check. No release publication or Git push.

## Artwork and integration

`Focus/AmbientMetal.swift` hosts an `MTKView` beneath the existing SwiftUI Focus UI.
`AmbientShader.swift` contains original Metal Shading Language source, compiled once
per process and shared across display renderers. No downloaded graphics, video,
third-party dependency or proprietary Apple artwork is used.

Four large parametric ribbon sheets have independent spines, changing widths,
camber and torsion. GPU-generated geometry (192 longitudinal × 32 transverse cells
per sheet) bends and rolls through a perspective camera. Surface normals drive
soft directional lighting, restrained specular sheen and grazing-angle highlights.
Depth-tested folds, transmitting edges and ordered alpha compositing reveal
underlying volumes. Grazing contours feather out to soften moving silhouettes.
The backdrop shifts subtly behind the sheets, with slower global rotation adding
parallax. This is procedural geometry, not animated static gradient points.

Four continuous phase coordinates advance at different rates. Double-precision
CPU phase evaluation and bounded trigonometric GPU coordinates avoid loss of
precision over long sessions. Each phase wraps only at an equivalent point on its
sine/cosine cycle. There is no timed animation restart or reversing loop. Visible
motion occurs within three seconds without high-frequency noise or particles.
A pause freezes elapsed time; resume continues from the same shape rather than
jumping ahead by the sleep/occlusion duration. Theme changes blend for 1.8 seconds
only when motion is enabled.

Midnight, Aurora and Monochrome retain their original three RGB anchors. Shader
lighting interpolates these colors and darkens them; it adds no white/neon tint
or new theme. Monochrome stays neutral. Palette snapshot tests guard the anchors.
The existing contrast scrim, wordmark, clock, attention card, Liquid Glass settings,
hooks, external display selection, GUI inhibit and session/power policy remain.

The fallback for a missing Metal device or pipeline is a static gradient using the
same palette, logged through OSLog. Normal rendering uses no per-frame SwiftUI
invalidation, blur passes, texture assets, CPU mesh generation or
multisample buffer. A transient 32-bit depth attachment resolves overlapping folds. Each surface submits one backdrop and four ribbon draws.

## Scheduling and resource budget

- Nominal AC: request 60 fps, bounded by the screen's maximum refresh rate. MTKView
  schedules its display-linked updates at a supported cadence.
- Battery, Low Power Mode or fair thermal state: retain the previous 12 fps limit,
  and cap the longest drawable dimension at 1920 pixels.
- Motion disabled, Reduce Motion or serious/critical thermal state: no repeating
  draw loop. Render a single still when needed; resize/theme changes can invalidate it.
- Hidden/occluded/detached window: pause submissions and release drawables.
  Focus removal detaches the renderer and delegate. Existing display/system sleep
  state also sets the requested cadence to zero. No power assertion is owned here.
- Nominal resolution caps the longest dimension at 3840 pixels; larger Retina
  backing surfaces are scaled proportionally. Text and glass stay at native backing
  resolution. Portrait and non-16:9 displays preserve their aspect ratio.
- At most two GPU command buffers are in flight; skip a frame instead of blocking
  the main thread. Sample completed GPU durations once per 30 frames. If GPU work
  exceeds 40% of the frame interval, reduce render scale in 0.125 steps down to 0.5;
  sustained headroom restores it slowly. Battery/thermal safeguards remain stronger
  than this feedback. There is no timer in a static view.

See Apple's [MTKView documentation](https://developer.apple.com/documentation/metalkit/mtkview)
for its draw modes and [preferredFramesPerSecond](https://developer.apple.com/documentation/metalkit/mtkview/preferredframespersecond)
for supported display cadence behavior.

## Reproduction and visual review

The developer-only review tool is never bundled into Still.app and does not start
Still's session/power controller:

```sh
Scripts/review-design.sh --ambient-frames .build/design-review/cinematic
.build/design-review/StillVisualReview --motion-frames .build/design-review/motion
.build/design-review/StillVisualReview --benchmark 3840 2160 300
.build/design-review/StillVisualReview --verify-ambient
.build/design-review/StillVisualReview --profile 60 3840 2160
```

`--ambient-frames` directly reads Still's own Metal render target at 3840×2160 for
all three themes at 0, 3, 5 and 18 seconds, and creates wordmark/clock compositions.
These are app-only renderer previews, not installed fullscreen screenshots. Their
text composition is illustrative; native glass compositing and actual panel output
need physical review. No desktop pixels or unrelated applications are captured.
`--motion-frames` creates eight seconds at 1280×720/30 fps for an animation preview.
`--benchmark` measures serialized, completed command-buffer GPU durations with
15 warm-up frames; it does not measure display FPS or whole-system GPU utilization.

`--profile 60 3840 2160` opens a finite 35-second native window, logs actual content
bounds, backing size and drawable dimensions, samples GPU completion and drawable
presentation timestamps, then exercises hide, resume and static mode. A review
assertion rejects a stale 1×1 drawable. CPU/RSS observations are collected externally
with `ps`. Telemetry callbacks add overhead compared with production's sparse GPU
sampling. Synthetic/virtual window presentations do not prove physical 4K display
performance, and other applications were running during these short observations.

## Required physical checks

- BenQ PD2705U/27-inch 4K on AC: inspect folds, highlights, edge softness, banding,
  3–5 second motion and text/card readability from a normal viewing distance.
- Real built-in/external and multiple-display resize, rotation, hotplug, Spaces,
  screen lock, lid closure and display/system sleep/wake ordering.
- Change all themes during motion; toggle motion and macOS Reduce Motion, including
  while hidden; verify immediate static behavior and a gentle resume.
- Battery, Low Power Mode and real thermal state transitions; sustained energy/GPU
  use, hours-long memory behavior and simultaneous covers on multiple displays.
- Real Claude Code/Codex attention cards and clock over the evolving image, live
  glass, GUI automation pause/return, and existing timeout/battery session stops.

No battery-life estimate, whole-system GPU utilization, thermal endurance, leak-free
long-session claim or physical 4K/60 guarantee is inferred from the local tests.

## Verified local result

- `swift test`: 14 tests, zero failures. Includes cadence/stop policy, week/year
  phase precision and continuity, render-target budget, exact palette anchors,
  preference migration and existing hook/inbox/display-selection tests.
- `swift run StillCheck`: 146 checks passed; session and power checks preserved.
- `python3 Scripts/test-focus-hooks.py`: four tests passed.
- Review tool `--verify-ambient`: seven GPU image checks passed. After three seconds,
  50.03% of Midnight, 51.50% of Aurora and 45.58% of Monochrome pixels changed by
  at least three 8-bit channel levels. Palette bounds, opaque compositing and
  Monochrome neutrality passed. Four phase-wrap comparisons had mean channel
  error below 0.009/255 and fewer than 0.002% of channels changing over three levels.
  These numeric checks complement inspected images; they are not human design acceptance.
- Final 4K app-only images at four timestamps per theme were inspected. Rounded folds,
  overlapping volumes and highlight movement are visible; the wordmark and clock
  remain readable. Depth slices per sheet avoid intersection cutouts while resolving
  each sheet's own folds and retaining ordered translucency.
### Final short profiling observations

Host: Apple M2 Max, 32 GB RAM, nominal temperature and AC. Actual native window
content was 3840×2160 points at backing scale 2; the renderer correctly capped the
nominal drawable to 3840×2160 pixels. Other applications were running. These are
short observations, not controlled battery or physical-display benchmarks.

Nominal 60-fps run: 1,620 GPU completion samples averaged 0.748 ms, p95 0.966 ms.
1,619 positive drawable presentation timestamps measured 59.996 fps, with a p95
interval of 16.668 ms. Fourteen two-second process observations ranged 2.0–9.3%
CPU (arithmetic mean 7.34%) and 73,952–76,304 KiB RSS. RSS is process resident memory,
not a measurement of total graphics/unified-memory allocations. The presentation
callbacks do not prove what a physical 27-inch panel displayed.

Hidden-window submissions after draining: zero. Resume restarted submissions.
Switching to static mode submitted one final invalidated frame and paused.
The actual Reduce Motion, battery/Low Power and thermal gates are covered by policy
tests; the harness exercises their target cadence/static rendering behavior without
changing global macOS accessibility or energy settings.

Constrained 12-fps run: actual drawable 1920×1080 pixels; 323 GPU samples averaged
0.244 ms, p95 0.517 ms. Presentation cadence was 11.999 fps (323 timestamps), p95
interval 83.339 ms. Fourteen two-second process observations ranged 0.1–2.0% CPU
(mean 0.386%) and 76,128–77,040 KiB RSS. Hidden submission delta was zero; static
mode drew once and paused. This simulates the constrained rendering request on AC;
it is not a real battery-discharge measurement.

Raw profiling traces, logs and generated previews remain local and are excluded from Git.

## Still 2.0 RC update

The 1.2 measurements and dark-only palette limits above are historical. Still 2.0 adds separate daytime palettes and broader satin highlights; see RELEASE-CANDIDATE.md for the current six-combination GPU checks, native profiling and remaining hardware validation. Appearance is independent of theme.
