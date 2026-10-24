import AppKit
import SwiftUI

struct FocusAmbientView: View {
    @EnvironmentObject var focus: FocusController
    @EnvironmentObject private var appearance: AppearanceController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private var fps: Double {
        AmbientPolicy.frameRate(visible: focus.active && !focus.renderingSuspended,
                                motion: focus.settings.motion, reduceMotion: reduceMotion,
                                lowPower: focus.lowPower, onBattery: focus.onBattery, thermal: focus.thermal)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AmbientBackground(theme: focus.settings.theme, framesPerSecond: fps)
                // Contrast is independent of the chosen ambient palette.
                (scheme == .light ? Color.white : Color.black).opacity(contrast == .increased ? 0.28 : 0.12)
                VStack(spacing: 22) {
                    Text("still.")
                        .font(.system(size: min(154, geometry.size.width * 0.16), weight: .light))
                        .tracking(-5)
                    HStack(spacing: 8) {
                        Circle().fill(.primary.opacity(0.8)).frame(width: 4, height: 4).accessibilityHidden(true)
                        Text(focus.activity).font(.system(size: 12, weight: .medium)).tracking(0.3)
                    }
                    .foregroundStyle(.primary.opacity(0.8))
                }
                // Very slow drift of the complete lockup discourages image retention.
                .offset(x: fps > 0 && appeared ? 7 : 0, y: fps > 0 && appeared ? -5 : 0)
                .animation(fps > 0 ? .easeInOut(duration: 46).repeatForever(autoreverses: true) : nil, value: appeared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    HStack(alignment: .top) {
                        Text("FOCUS").font(.system(size: 10, weight: .medium)).tracking(3)
                        Spacer()
                        if focus.settings.clock {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text(context.date, format: .dateTime.hour().minute())
                                    .font(.system(size: 21, weight: .light)).monospacedDigit()
                                    .accessibilityLabel("Time")
                            }
                        }
                    }
                    .foregroundStyle(.primary.opacity(0.8))
                    Spacer()
                    if let event = focus.pending.first {
                        AttentionCard(event: event, focus: focus, ambient: true)
                            .frame(maxWidth: 440)
                            .id(event.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        if focus.pending.count > 1 {
                            Text("\(focus.pending.count - 1) more in Still").font(StillDesign.caption)
                                .foregroundStyle(.primary.opacity(0.8)).padding(.top, 6)
                        }
                    }
                    Text("esc or click to leave  ·  Still menu for controls  ·  not a screen lock")
                        .font(.system(size: 11)).foregroundStyle(.primary.opacity(0.8)).padding(.top, 24)
                }
                .padding(max(24, min(60, geometry.size.width * 0.05)))
                .animation(reduceMotion ? nil : StillDesign.spring, value: focus.pending.map(\.id))
            }
            .foregroundStyle(scheme == .light ? StillDesign.ink : StillDesign.ambientText)
            .contentShape(Rectangle())
            .onTapGesture { focus.stop() }
            .accessibilityAction(named: "Leave Focus") { focus.stop() }
            .opacity(appeared ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: appeared)
            .onAppear { appeared = true }
        }
        .preferredColorScheme(appearance.preference.colorScheme)
    }
}

struct AttentionCard: View {
    let event: FocusEvent
    @ObservedObject var focus: FocusController
    var ambient = false
    @Environment(\.colorScheme) private var scheme
    private var ink: Color { scheme == .dark ? Color(white: 0.94) : StillDesign.ink }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.kind == .permission ? "hand.raised" : "text.bubble")
                    .font(.system(size: 17, weight: .light)).frame(width: 24, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.provider.name).font(.system(size: 12, weight: .semibold))
                    Text(event.project).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(event.kind.context).font(StillDesign.caption).foregroundStyle(ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if ambient {
                Text("Return to \(event.provider.name) from the Still menu ↑")
                    .font(.system(size: 12, weight: .medium))
            } else {
                HStack {
                    Button("Return to agent", systemImage: "arrow.up.forward") { focus.returnToAgent(event) }
                        .buttonStyle(.glass).accessibilityHint("Leaves Focus and activates the agent’s app. Request remains available.")
                    Spacer(minLength: 0)
                    Button("Dismiss") { focus.dismiss(event) }.buttonStyle(.plain).foregroundStyle(ink.opacity(0.8))
                        .accessibilityLabel("Dismiss request from \(event.provider.name), \(event.project)")
                }
                .font(StillDesign.caption)
            }
        }
        .foregroundStyle(ink)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StillGlass())
        .accessibilityElement(children: .contain)
    }
}

public struct FocusMenuView: View {
    @ObservedObject var focus: FocusController
    let activate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(focus: FocusController, activate: @escaping () -> Void) { self.focus = focus; self.activate = activate }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().padding(.vertical, 4)
            HStack(spacing: 10) {
                Image(systemName: "moon.stars").font(.system(size: 17, weight: .light)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Still Focus").font(.system(size: 13, weight: .medium))
                    Text(focus.active ? "\(focus.settings.theme.name) · Escape to leave" : "A quiet place for work to finish")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Toggle("Still Focus", isOn: Binding(get: { focus.active }, set: { $0 ? activate() : focus.stop(animated: true) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityHint("Covers selected displays. Uses the session safety timeout.")
            }
            if let note = focus.note { InlineNotice(text: note) }
            if !focus.pending.isEmpty {
                HStack {
                    Text("Needs your attention").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(focus.pending.count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(focus.pending) { event in AttentionCard(event: event, focus: focus) }
                    }.padding(2)
                }.frame(maxHeight: 210)
            }
        }
        .animation(reduceMotion ? nil : StillDesign.spring, value: focus.pending.map(\.id))
        .padding(.top, 12)
    }
}

struct FocusSettingsView: View {
    @ObservedObject var focus: FocusController
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StillSection(title: "Ambient theme") {
                HStack(spacing: 8) {
                    ForEach(AmbientTheme.allCases) { theme in
                        Button { focus.settings.theme = theme } label: {
                            VStack(spacing: 7) {
                                AmbientBackground(theme: theme).frame(height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .bottomTrailing) {
                                        if focus.settings.theme == theme {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(scheme == .light ? Color.black : Color.white)
                                                .font(.system(size: 12)).padding(5)
                                        }
                                    }
                                Text(theme.name).font(.system(size: 10, weight: focus.settings.theme == theme ? .semibold : .regular))
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("\(theme.name) theme")
                        .accessibilityAddTraits(focus.settings.theme == theme ? .isSelected : [])
                    }
                }
                StillToggle("Show clock", isOn: $focus.settings.clock)
                StillToggle("Ambient motion", isOn: $focus.settings.motion)
                Text("Motion slows on battery and pauses with Reduce Motion or elevated temperature.")
                    .font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            StillSection(title: "Displays") {
                StillToggle("Select automatically", isOn: Binding(get: { focus.settings.displays == nil }, set: {
                    focus.settings.displays = $0 ? nil : FocusDisplayPolicy.selected(focus.displays, preference: nil).sorted()
                }))
                if focus.displays.isEmpty {
                    Label("No connected displays", systemImage: "display").foregroundStyle(.secondary)
                }
                ForEach(focus.displays) { display in
                    Toggle(isOn: Binding(get: {
                        FocusDisplayPolicy.selected(focus.displays, preference: focus.settings.displays).contains(display.id)
                    }, set: { focus.selectDisplay(display.id, enabled: $0) })) {
                        Label(display.name, systemImage: display.builtIn ? "laptopcomputer" : "display")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Automatic selection prefers external displays.").font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            StillSection(title: "Agent attention") {
                Picker("Sound", selection: $focus.settings.sound) {
                    ForEach(["None", "Glass", "Submarine", "Pop"], id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Image(systemName: "speaker.wave.1").accessibilityHidden(true)
                    Slider(value: $focus.settings.volume, in: 0...1) { Text("Attention volume") }
                        .labelsHidden().accessibilityLabel("Attention volume")
                    Image(systemName: "speaker.wave.3").accessibilityHidden(true)
                }.foregroundStyle(.secondary).disabled(focus.settings.sound == "None")
                StillToggle("Native agent notifications", isOn: $focus.settings.nativeNotifications)
                Text("Banners can appear during Focus. In macOS Notifications, allow banners and sounds for Still and your agent apps. macOS Focus modes can silence them.")
                    .font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if focus.settings.nativeNotifications && focus.notificationStatus == .denied {
                    InlineNotice(text: "Notifications are off in macOS. Attention requests remain in Still.", symbol: "bell.slash")
                    Button("Open Notification Settings…") { focus.openNotificationSettings() }.buttonStyle(.glass)
                }
                StillToggle("Focus when an agent starts", isOn: $focus.settings.autoActivate)
                Text("Requires agent hooks. Codex permission alerts also require user-routed approvals and trusted hooks. Requests are never approved automatically.")
                    .font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            StillSection(title: "Compatibility") {
                StillToggle("Foreground GUI automation", isOn: $focus.settings.guiAutomation)
                Text("Pauses Focus for mouse and window automation. Resume Focus manually when finished. Clicking the cover exits Focus; it does not lock your Mac or prevent capture.")
                    .font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(StillDesign.body).toggleStyle(.switch).controlSize(.small)
        .onAppear { focus.refreshNotificationStatus() }
    }
}
