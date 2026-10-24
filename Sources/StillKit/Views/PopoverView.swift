import AppKit
import SwiftUI

extension AppModel {
    var markStyle: MarkView.Style {
        if restoring { return .paused }
        switch phase {
        case .active: return .active
        case .suspended: return .paused
        case .inactive: return .idle
        }
    }

    func summary(now: Date) -> StatusSummary {
        StatusSummary.make(
            decision: decision,
            restoring: restoring,
            streamName: targets.first?.name,
            streamActive: streamActive,
            agent: agent,
            batteryFloor: batteryFloor,
            now: now
        )
    }
}

public struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MarkRenderer.menuBarImage(style: model.markStyle))
            if model.showMenuBarWordmark {
                Text(Brand.wordmark)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Still: \(model.restoring ? "restoring sleep" : model.appliedHold ? "Mac active" : "ready")")
    }
}

public struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appearance: AppearanceController
    public init() {}
    public var body: some View {
        Group {
            if model.showWelcome { WelcomeView { model.completeWelcome() } }
            else if model.showSettings { SettingsView() }
            else { MainView() }
        }
        .frame(width: StillDesign.width)
        .preferredColorScheme(appearance.preference.colorScheme)
        .tint(StillDesign.accent)
        .animation(reduceMotion ? nil : StillDesign.spring, value: model.showSettings)
        .animation(reduceMotion ? nil : StillDesign.spring, value: model.privilegeGranted)
    }
}

private struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                MarkView(style: model.markStyle).frame(width: 28, height: 28).accessibilityHidden(true)
                Wordmark(size: 19)
                Spacer()
                QuietIconButton(title: "Settings", symbol: "slider.horizontal.3") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                StatusBlock(summary: model.summary(now: context.date))
            }.padding(.top, 24)
            if let warning = model.flagWarning { WarningNote(warning: warning).padding(.top, 16) }
            if let note = model.actionNote { InlineNotice(text: note).padding(.top, 16) }
            PrimaryAction().padding(.top, 24)
            SafetyLine().padding(.top, 16)
            FocusMenuView(focus: model.focus) { model.startFocus() }
        }
        .padding(StillDesign.inset)
    }
}

struct StatusBlock: View {
    let summary: StatusSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(summary.tone == .paused ? Color.orange : summary.tone == .active ? StillDesign.accent : Color.secondary)
                    .frame(width: 5, height: 5).accessibilityHidden(true)
                Text(summary.tone == .active ? "SESSION IN PROGRESS" : summary.tone == .paused ? "SESSION PAUSED" : "READY WHEN YOU ARE")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            }
            Text(summary.title).font(.system(size: 32, weight: .medium)).tracking(-0.8)
            Text(summary.reason).font(StillDesign.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let remaining = summary.remaining {
                Text(remaining).font(StillDesign.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText()).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: summary)
        .accessibilityElement(children: .combine)
    }
}

private struct PrimaryAction: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 11) {
            Button { model.setManualArmed(!model.holdSwitchOn) } label: {
                Text(model.holdSwitchOn ? "End session" : "Keep Mac Active")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 27)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .tint(model.holdSwitchOn ? Color.secondary : StillDesign.accent)
            .disabled(model.restoring)
            if !model.holdSwitchOn {
                Menu {
                    Picker("Safety timeout", selection: $model.safetyTimeout) {
                        ForEach(SafetyTimeout.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    Text(model.safetyTimeout == .untilDisabled ? "Until I turn it off" : "For \(model.safetyTimeout.label)")
                        .font(StillDesign.caption)
                }
                .menuStyle(.button).buttonStyle(.plain).foregroundStyle(.secondary)
                .fixedSize().frame(maxWidth: .infinity)
                .accessibilityLabel("Safety timeout: \(model.safetyTimeout.label)")
                if model.safetyTimeout == .untilDisabled {
                    Text("No time limit. Battery and thermal safeguards still apply.")
                        .font(StillDesign.caption).foregroundStyle(.secondary)
                }
            } else if model.appliedHold {
                Button("Sleep Now") { model.sleepNow() }.buttonStyle(.plain).font(StillDesign.caption)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SafetyLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.onBattery ? "battery.50percent" : "bolt.shield")
            Text(model.onBattery && model.batteryPercent >= 0 ? "\(model.batteryPercent)% · pauses below \(model.effectiveBatteryFloor)%" : "Battery & thermal safeguards on")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct WarningNote: View {
    @EnvironmentObject var model: AppModel
    let warning: AppModel.FlagWarning
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InlineNotice(text: warning == .external ? "Another app has turned off normal sleep on this Mac." : "Normal sleep wasn’t restored earlier.")
            if warning == .staleNoPrivilege {
                Button("Recover Normal Sleep…") { model.beginSetup() }.buttonStyle(.glass).controlSize(.small)
            } else {
                Text("Check other awake apps or system power settings. Still does not change settings owned by another app.")
                    .font(StillDesign.caption).foregroundStyle(.secondary)
            }
        }.padding(14).modifier(StillGlass())
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appearance: AppearanceController
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var removeAccess = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                QuietIconButton(title: "Back to Still", symbol: "chevron.left") { model.showSettings = false }
                Text("Settings").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            Picker("Settings category", selection: $tab) {
                Text("Session").tag(0); Text("Focus").tag(1); Text("General").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == 0 { sessionSettings }
                    else if tab == 1 { FocusSettingsView(focus: model.focus) }
                    else { generalSettings }
                }
                .padding(.vertical, 4).padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 370).scrollIndicators(.automatic)
            HStack {
                Button("Quit Still") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
                Spacer()
                Text("Still \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0")")
            }.font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(StillDesign.body).toggleStyle(.switch).controlSize(.small)
        .padding(StillDesign.inset)
        .onAppear { model.refreshLoginItem(); model.refreshPermissions() }
        .confirmationDialog("Remove Still’s administrator access?", isPresented: $removeAccess) {
            Button("Remove access", role: .destructive) { model.removeAccess() }
        } message: { Text("Removes the old administrator rule. Current awake sessions do not need administrator access.") }
    }
    private var sessionSettings: some View {
        Group {
            StillSection(title: "Safety") {
                Stepper(value: $model.batteryFloor, in: 5...50, step: 5) {
                    Text("Pause below \(model.effectiveBatteryFloor)% battery").monospacedDigit()
                }
                Picker("Safety timeout", selection: $model.safetyTimeout) {
                    ForEach(SafetyTimeout.allCases) { Text($0.label).tag($0) }
                }
                Text("Sessions end within three hours and pause at 15% battery or your higher chosen threshold. Temperature and Low Power Mode safeguards always apply.")
                    .font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            StillSection(title: "Streaming") {
                StillToggle("Stay active while streaming", isOn: $model.autoDetectEnabled)
                StillToggle("Resume playback after lid closes", isOn: $model.resumePlaybackEnabled).disabled(!model.autoDetectEnabled)
                Text("Closing the lid without an external display may put this Mac to sleep. With an external display, macOS manages clamshell mode; Still releases its awake session.")
                    .font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.resumePlaybackEnabled && model.resumeNeedsPermission {
                    InlineNotice(text: "Allow Accessibility access to resume playback.", symbol: "hand.raised")
                    Button("Open Privacy & Security…") { model.openAccessibilitySettings() }.buttonStyle(.glass)
                }
            }
            StillSection(title: "Agents") {
                StillToggle("Stay active while agents work", isOn: $model.aiDetectEnabled)
                Text("Claude Code & Codex. Recent session activity keeps your Mac awake; attention requires explicit agent events.")
                    .font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var generalSettings: some View {
        Group {
            StillSection(title: "Appearance") {
                Picker("Appearance", selection: $appearance.preference) {
                    ForEach(AppearancePreference.allCases) { Text($0.label).tag($0) }
                }
                Text("Applies to Still and Focus. Choose the ambient theme separately in Focus.")
                    .font(StillDesign.caption).foregroundStyle(.secondary)
            }
            StillSection(title: "Everyday") {
                StillToggle("Open at login", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
                if let note = model.loginItemNote {
                    InlineNotice(text: note, symbol: "info.circle")
                    if model.loginItemNeedsApproval {
                        Button("Open Login Items…") { model.openLoginItemsSettings() }.buttonStyle(.glass)
                    }
                }
                StillToggle("Show name in menu bar", isOn: $model.showMenuBarWordmark)
            }
            StillSection(title: "About & help") {
                Button("About Still…") { AboutWindow.show(appearance: appearance) }.buttonStyle(.glass)
                Button("How Still works…") { model.showWelcome = true; model.showSettings = false }.buttonStyle(.plain)
            }
            StillSection(title: "Administrator access") {
                Text("Awake sessions use native macOS assertions and need no administrator access.").foregroundStyle(.secondary)
                if model.privilegeGranted {
                    Text("An older Still administrator rule is still installed. You can remove it.").foregroundStyle(.secondary)
                    Button("Remove Legacy Access…", role: .destructive) { removeAccess = true }.buttonStyle(.glass)
                }
            }
        }
    }
}
