import AppKit
import SwiftUI

struct WelcomeView: View {
    var continueAction: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { MarkView(style: .active).frame(width: 42, height: 42); Spacer(); Text("WELCOME TO STILL").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Room to finish.").font(.system(size: 30, weight: .medium)).tracking(-0.8)
                Text("Keep your Mac awake. Let your work continue.").font(StillDesign.body).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    explanation("An awake session", "Start a timed session from the menu bar. Streaming and Claude Code or Codex detection are optional. Ending a session restores normal sleep.", icon: "timer")
                    explanation("A quieter display", "Still Focus covers your selected displays with ambient artwork. Escape leaves Focus; End session also releases the awake hold. Focus is not a screen lock and cannot guarantee an external display stays awake.", icon: "display")
                    explanation("You stay in control", "Apple-menu sleep always takes priority. Closing the lid without an external display may sleep your Mac. With an external display, macOS manages clamshell mode. Notifications need your permission; agent hooks never approve requests.", icon: "hand.raised")
                    explanation("Safeguards, always", "Low battery, elevated temperature and Low Power Mode pause awake sessions. Keep your Mac ventilated, even with the lid closed.", icon: "bolt.shield")
                }.padding(.trailing, 6)
            }.frame(maxHeight: 310)
            Button(action: continueAction) { Text("Continue").frame(maxWidth: .infinity, minHeight: 26) }
                .buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(StillDesign.inset).frame(width: StillDesign.width)
    }
    private func explanation(_ title: String, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .light)).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(StillDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 88, height: 88).accessibilityHidden(true)
            Text("Still").font(.system(size: 29, weight: .medium)).tracking(-0.7)
            Text("Room to finish.").font(.system(size: 14)).foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0") · RC 1\nBuild \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5")")
                .font(StillDesign.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Text("Awake sessions, thoughtful safeguards,\nand a quieter place for work to finish.")
                .font(StillDesign.body).multilineTextAlignment(.center)
            Text("Local processing · No analytics · No automatic updates")
                .font(StillDesign.caption).foregroundStyle(.secondary)
            Text("© 2026 Still · MIT License").font(StillDesign.caption).foregroundStyle(.secondary)
        }.padding(36).frame(width: 380).background(.background)
    }
}

@MainActor
enum AboutWindow {
    private static var window: NSWindow?
    static func show(appearance: AppearanceController) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 410), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        created.title = "About Still"
        created.isReleasedWhenClosed = false
        created.contentView = NSHostingView(rootView: AboutView())
        created.center(); created.makeKeyAndOrderFront(nil); NSApp.activate()
        window = created
    }
}

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    static func show(appearance: AppearanceController, completion: @escaping () -> Void) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: StillDesign.width, height: 560),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        created.title = "Welcome to Still"
        created.isReleasedWhenClosed = false
        created.contentView = NSHostingView(rootView: WelcomeView {
            completion()
            window?.close()
            window = nil
        }.tint(StillDesign.accent))
        created.center(); created.makeKeyAndOrderFront(nil); NSApp.activate()
        window = created
    }
}
