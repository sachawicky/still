# Still Focus

Still Focus is a visual display cover, not a screen lock. It never hides content
from screen capture and does not power down a monitor. The menu bar and macOS
security controls remain available. Background CLI agents, scripts and networking
continue under Still's existing awake policy.

## Use

Open Still's menu, enable **Still Focus**. Open **Settings → Focus** to choose one or
more displays (external displays by default), ambient theme, clock, motion, sound,
volume, native notifications and optional session-start activation (OFF by default).
Display UUIDs survive reconnects; removed displays lose their windows immediately.
An explicitly selected disconnected monitor does not silently redirect to another
monitor. The automatic selection follows available external displays, falling back
to the built-in screen if none exist. Mirrored displays share their desktop and
cannot provide independent privacy surfaces.

Escape or Command-period exits while Still has keyboard focus. These are local
shortcuts; no global shortcut or Accessibility permission is installed. A click on the ambient background exits immediately and is consumed by Still. The Still
menu toggle always exits. Returning to another app can move keyboard focus away
from Still; use the menu in that case. Leaving Focus alone does not stop the awake
session: use Still's existing **Stop** button to release it.

If no awake session exists, activation requests a finite session using the existing
Safety Timeout (three hours if the manual setting was unlimited). An existing
explicit awake session keeps its current deadline. Battery, thermal, low-power and timeout safeguards remain active. Sleep, lock and
session deactivation close Focus and require explicit resume. With an external
display connected, macOS manages clamshell behavior and Still releases its own
assertion; Focus can remain visible. New sessions require no administrator access. No new power controller or display assertion is
created. Focus does not start automatically on app launch.

## Attention integration

The per-user mailbox is `~/Library/Application Support/Still/FocusEvents` (0700,
files 0600). It is watched with DispatchSource, not polled. Hooks run the installed
executable in an early-exit mode; they never launch a second menu bar/power manager.
Only a provider, hashed session/deduplication key, project basename, event kind,
timestamp and allowlisted terminal bundle ID are stored. Commands, transcript
contents and question text are not stored or displayed. Project basenames may
still be sensitive: disable hooks if even those must not be shown. This is local
same-user IPC, not a security boundary against other programs running as you.

Requests remain on disk until dismissed, including across application restarts.
Returning to an agent ends Focus and activates a known running terminal when
`TERM_PROGRAM` identifies it; it cannot select a particular tab, window or chat.
Otherwise Still asks you to switch manually. Return does not claim the request
has been answered. Multiple requests are listed in the menu; up to three appear
on the ambient screen. Identical outstanding requests are deduplicated. The queue
is capped at 512 files; further hook writes report failure on stderr, without
blocking or deciding agent permissions. Restoring requests does not replay sounds.
Native alerts inside and outside Focus require the preference and macOS authorization;
the in-app queue works even when notification permission is denied. Build 7 adds an
explicit opt-in command that preserves all other and future Focus preferences; see
[notification setup and diagnostics](POWER-SAFETY.md#activation-et-désactivation-des-notifications).
Foreground presentation allows banners and Notification Center entries. macOS
notification settings and Focus modes still control actual visibility. Attention
sounds play once through NSSound using the chosen sound and app volume; banners
do not play a duplicate sound. Still changes neither system volume/mute nor
third-party permissions, and cannot guarantee an audible sound.

### Installation

After installing Still, preview then merge the passive hooks:

```sh
python3 Scripts/configure-focus-hooks.py
python3 Scripts/configure-focus-hooks.py --apply
```

Existing JSON settings/hooks are retained. Each changed existing file gets an
exact mode-0600 backup alongside it. Invalid JSON and symlinks fail closed. The
script does not change MCP, permission policies, agent rules or hook trust. Open
new agent sessions after installation. Codex requires manual review/trust using
`/hooks`; Still never bypasses that review. To uninstall, remove only entries whose
command invokes Still with `--focus-hook`; do not restore whole old configurations
if other settings have since changed.

### Claude Code

Uses documented `Notification` types `permission_prompt`, `elicitation_dialog`,
`elicitation_url_dialog` and `agent_needs_input`. These report actual actionable
notifications. Ordinary `idle_prompt`, completion, Stop and auth notifications
are ignored. PermissionRequest itself is deliberately not used because another
hook may answer it before a user prompt is needed. A regular question that produces
no actionable Notification in that Claude version/surface is not inferred from
text or idle time. Newer notification types require a supporting Claude version.

### Codex

Uses documented lifecycle and local function-tool hooks. `SessionStart` supports
optional activation. `PreToolUse` for the exact tool `request_user_input` with
nonempty structured questions reports an explicit input request when that tool
uses the local hook path. Some specialized tool paths opt out of hooks; this is
not guaranteed on every desktop/CLI version. Ordinary assistant prose, async
questions without that hook, transcript contents, token pauses, completion and
inactivity are not interpreted as requests. The generic `notify` completion
mechanism is not repurposed as attention detection.

PermissionRequest is implemented but **disabled by default**: its documented
payload does not establish whether an approval is routed to the user or automatic
review. Only for sessions configured to send all such approvals to the user:

```sh
python3 Scripts/configure-focus-hooks.py --provider codex --codex-user-approvals --apply
```

This flag is an explicit operator assertion about approval routing, not automatic
detection. Do not enable it for auto_review / Approve for me or sessions where
another hook supplies permission decisions. Review the new definition with
`/hooks`. Global hook scope can cover several sessions with different routing;
use a trusted project config via `--config-root /path/to/project` instead when
needed. Still does not change routing itself and never returns allow/deny output.
There is no reliable blanket attention detection for arbitrary existing Codex
sessions; unsupported events remain in Codex's own UI.

## Foreground automation

Before any screenshot/mouse/window automation, enable **Foreground GUI automation
active** in Focus settings. This closes Focus and prevents manual/automatic
activation until cleared. Integrators can bracket automation with:

```sh
/Applications/Still.app/Contents/MacOS/Still --focus-gui begin
# Run GUI automation only if the command succeeded.
/Applications/Still.app/Contents/MacOS/Still --focus-gui end
```

The begin command waits up to three seconds for the running app to close its
windows and consume the signal. Failure is exit 1; do not start automation until
Still is running and the overlay is confirmed gone. End only clears the inhibit;
it never automatically covers a foreground workflow again. The inhibit persists
through restarts. A background click is consumed to close Focus immediately; it is
not forwarded to the application behind the cover. Automation must still pause
Focus before sending mouse or keyboard events. There is no supported universal macOS
signal identifying all GUI agents. Still cannot auto-detect arbitrary GUI tools,
does not request Accessibility access for Focus, and does not promise invisible
GUI automation. CLI work needs no compatibility pause.

## Physical display sleep

No per-monitor power-off implementation was added. The public AppKit screen/window
APIs and IOKit power assertions examined do not establish a reliable supported
per-external-monitor sleep/wake interface. Apple's documented power assertions
manage system/display idleness, not a selected BenQ power state. We intentionally
avoid private display APIs, DDC assumptions and global `pmset displaysleepnow`
workarounds. You may use the monitor's physical power control, but USB-C power,
hub behavior and disconnect effects require hardware validation. Still cannot
show visible alerts on a powered-off display or promise to wake it. No global
power setting is modified for Focus.

## Architecture / audit

- Existing Swift package: macOS 26+, SwiftUI MenuBarExtra, AppKit integration,
  bundle `app.still.macos`; release/install scripts retained.
- `DetectionCenter`/`AgentWatcher` already watch transcript file writes for coarse
  activity and power policy. This remains unchanged. The display labels that
  evidence as **recent session activity**, not a reliable agent execution state.
- `SessionPolicy`, `SleepController` and existing AssertionController retain power
  ownership, timeout, reconciliation, battery/thermal/low-power protections.
- FocusState contains a provider protocol, documented hook adapter, pure display
  selection, persistent preferences and attention reduction. FocusInbox is bounded
  private disk IPC. FocusController owns windows, observers and notification
  routing. FocusViews renders the ambient cover and native menu/settings controls.
- Ambient uses original Metal ribbon geometry at up to 60 fps (display permitting),
  reduced to 12 fps and a smaller render target on battery, Low Power Mode or fair
  temperature. Reduce Motion, motion disabled and serious/critical temperature
  freeze the image. Hidden/detached covers and system/display sleep stop submissions.
  The clock updates once per minute. See [ambient rendering and validation](AMBIENT-RENDERING.md).
- No dependency, daemon, privileged helper, global keyboard tap, or private API
  was added.

## Manual validation — BenQ PD2705U and agent prompts

1. Connect the BenQ on AC. Enable Focus: BenQ is selected by default. Try custom
   built-in/external selections, resolution changes and multiple Spaces. Verify
   coverage, accessible menu bar, Escape while Still is focused, and menu exit.
2. Unplug/reconnect BenQ. Its window must close/reappear according to selection;
   an explicitly selected missing display must not cover a different screen.
   Check lid closure with a background terminal counter/network task and reopen.
3. Set a short test deadline in a development test, or let the actual timeout
   expire. Verify normal sleep returns and Focus closes. Do not induce unsafe
   thermal/battery conditions merely to test the policy; unit/existing policy
   checks cover those transitions.
4. In a NEW Claude session, trigger a real permission prompt and leave it pending
   for the provider's notification delay. Expect one card/sound. Trigger two
   independent requests, dismiss one, Return to the other, restart Still and
   verify the remaining request survives without replaying sound. Idle/completion
   must not make cards. Test an MCP elicitation where available.
5. Trust the Still Codex hooks via `/hooks`. Ask Codex a structured question in a
   mode offering `request_user_input`. Confirm the card on this exact version.
   In a separately verified user-approval-only session, enable the optional
   permission hook and trigger a real approval. In auto_review leave it OFF;
   automatic approvals must never generate Still permission cards.
6. Enable native notifications in Focus settings and grant the macOS prompt.
   With Focus off and on, repeat a real actionable event and click its banner. Also test
   denial / Do Not Disturb, sound None, volume, Reduce Motion and Low Power Mode.
7. Before foreground GUI automation, run `--focus-gui begin` and require exit 0.
   Verify Focus disappears and cannot reactivate. Run the GUI task visibly, send
   `end`, then manually restart Focus. Never run blind mouse automation over a
   covered screen.

Physical BenQ, real agent prompt delivery, audible output, notification authorization,
and GUI automation end-to-end tests require direct interaction and are not implied
by unit tests or a successful bundle build.

## Sources checked 18 October 2026

- [Claude hook reference](https://code.claude.com/docs/en/hooks#notification)
- [Official OpenAI documentation: hooks, tool coverage and trust](https://learn.chatgpt.com/docs/hooks)
- [Codex App Server](https://learn.chatgpt.com/docs/app-server): no takeover of an
  unrelated existing client's sessions is assumed.
- [Apple display-idle power assertion](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep)
- [Apple sleep/wake settings](https://support.apple.com/en-gb/guide/mac-help/mchle41a6ccd/mac)
