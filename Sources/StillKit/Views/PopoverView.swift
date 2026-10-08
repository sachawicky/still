import AppKit
import SwiftUI

private enum Metrics {
    static let width: CGFloat = 288
    static let gutter: CGFloat = 20
    static let radius: CGFloat = 14
}

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
        .accessibilityLabel(Brand.name)
    }
}

public struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if !model.privilegeGranted {
                SetupView()
            } else if model.showSettings {
                SettingsView()
            } else {
                MainView()
            }
        }
        .frame(width: Metrics.width)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.showSettings)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.privilegeGranted)
    }
}

// MARK: - Main

private struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                MarkView(style: model.markStyle)
                    .frame(width: 30, height: 30)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.markStyle)
                Wordmark()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .frame(height: 30)
                Spacer()
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }

            TimelineView(.periodic(from: .now, by: 15)) { context in
                StatusBlock(summary: model.summary(now: context.date))
                    .padding(.top, 14)
            }

            if let warning = model.flagWarning {
                WarningNote(warning: warning)
                    .padding(.top, 16)
            }

            Spacer().frame(height: 22)
            PrimaryAction()
        }
        .padding(Metrics.gutter)
    }
}

private struct StatusBlock: View {
    let summary: StatusSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(summary.tone == .idle ? .secondary : .primary)
            Text(summary.reason)
                .font(.system(size: 13))
                .foregroundStyle(summary.tone == .idle ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let remaining = summary.remaining {
                Text(remaining)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: summary)
    }
}

private struct PrimaryAction: View {
    @EnvironmentObject var model: AppModel

    private var running: Bool {
        model.holdSwitchOn
    }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                model.setManualArmed(!running)
            } label: {
                Text(running ? "Stop" : "Keep Mac Active")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(running ? Color.gray : Color.accentColor)
            .disabled(model.restoring)

            if !running {
                Menu {
                    Picker("Safety timeout", selection: $model.safetyTimeout) {
                        ForEach(SafetyTimeout.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(model.safetyTimeout == .untilDisabled ? "Until I turn it off" : "For \(model.safetyTimeout.label)")
                        .font(.system(size: 12))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .menuIndicator(.visible)
                .fixedSize()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Safety timeout: \(model.safetyTimeout.label)")
            } else if model.appliedHold {
                Button("Sleep Now") { model.sleepNow() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct WarningNote: View {
    @EnvironmentObject var model: AppModel
    let warning: AppModel.FlagWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(warning == .external
                ? "Another app has turned off normal sleep on this Mac."
                : "Normal sleep wasn’t restored earlier.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Restore Normal Sleep") { model.restoreNormalSleep() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

// MARK: - Setup (first launch)

private struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkView(style: .active)
                .frame(width: 40, height: 40)
            Text("Welcome to \(Brand.name)")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 16)
            Text("\(Brand.name) keeps your Mac active while the lid is closed, only for as long as something still needs to finish.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text("Because this changes how your Mac normally sleeps, a one-time administrator approval is needed.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Button {
                model.beginSetup()
            } label: {
                Text(model.setupInFlight ? "Waiting for approval…" : "Set Up")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.setupInFlight)
            .padding(.top, 22)

            Button("Quit \(Brand.name)") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .padding(Metrics.gutter)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    model.showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
            }

            Group {
                section("Safety") {
                    HStack {
                        Text("Pause below")
                        Spacer()
                        Stepper("\(model.batteryFloor)% battery", value: $model.batteryFloor, in: 5...50, step: 5)
                            .fixedSize()
                    }
                }
                section("Streaming") {
                    Toggle("Stay active while streaming", isOn: $model.autoDetectEnabled)
                    Toggle("Resume playback after closing the lid", isOn: $model.resumePlaybackEnabled)
                        .disabled(!model.autoDetectEnabled)
                    if model.resumePlaybackEnabled, model.resumeNeedsPermission {
                        Text("Needed to press Play for you after the lid closes.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Allow in Privacy & Security…") { model.openAccessibilitySettings() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                section("AI Work") {
                    Toggle("Stay active while Claude Code or Codex works", isOn: $model.aiDetectEnabled)
                }
                section("General") {
                    Toggle("Open at login", isOn: Binding(
                        get: { model.loginItemEnabled },
                        set: { model.setLoginItem($0) }
                    ))
                    if let note = model.loginItemNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if model.loginItemNeedsApproval {
                            Button("Open Login Items…") { model.openLoginItemsSettings() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Toggle("Show name in menu bar", isOn: $model.showMenuBarWordmark)
                    HStack {
                        Text("Administrator access")
                        Spacer()
                        Button("Remove") { model.removeAccess() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .font(.system(size: 13))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack {
                Button("Quit \(Brand.name)") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .padding(.top, 20)
        }
        .padding(Metrics.gutter)
        .onAppear {
            model.refreshLoginItem()
            model.refreshPermissions()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }
}
