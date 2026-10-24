# Still privacy and permissions — 2.0 RC

Still processes information locally. It has no analytics SDK, account, advertising, telemetry upload, update service, or network client. No data is sent to Still's developer. System crash reports remain under macOS diagnostics settings; users may voluntarily share a redacted report.

Preferences in the app.still.macos defaults domain store appearance, safety settings and session state. Focus preferences retain the stillFocusSettings.v1 key across upgrades. FSEvents observes writes under ~/.claude/projects and ~/.codex/sessions to estimate recent activity; Still does not parse transcript contents. This heuristic can mistake a recent write for ongoing work or miss a silent long task. Detection is optional. Files elsewhere are not scanned.

Agent hooks, when installed explicitly by the user, deliver sanitized provider, hashed session/deduplication IDs, project basename, event kind, optional terminal identifier and date to ~/Library/Application Support/Still/FocusEvents. No prompts, responses, commands, full project paths or transcripts are retained. Pending events persist until dismissed. Project names may appear on Focus displays and in optional macOS notifications: keep native notifications off for sensitive projects, or hide previews in macOS settings. Focus is not a privacy screen, lock, or capture prevention mechanism.

Current awake sessions require no administrator permission and install no privileged rule. Still never enables the system-wide SleepDisabled flag. A legacy Still-owned flag can be restored using an existing rule or a one-time interactive administrator recovery. The old rule is removed only when explicitly requested in Settings. Native process-owned assertions are released on process death and have a three-hour kernel timeout. Keep the Mac ventilated.

Accessibility allows optional media-key playback resume. Apple Events supports the explicit setup and Sleep Now actions. Notifications require separate consent and may be revoked in macOS settings; requests remain visible in Still. Launch at Login uses SMAppService and is optional. No Screen Recording, microphone, camera or Full Disk Access is requested.

Uninstall: end the session, remove administrator access in Settings, disable Open at login, quit Still, then remove Still.app. Preferences and pending requests can be removed separately by the user. Still never changes unrelated agent configuration without the explicit hook installation command.

Updates are manual. Public builds must have a valid Developer ID signature, Apple notarization and a published checksum. This RC is local and ad-hoc signed until those steps succeed.
