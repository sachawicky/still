import AppKit
import SwiftUI
import StillKit

final class AppDelegate: NSObject, NSApplicationDelegate {}

@main
struct StillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        UserDefaults.standard.register(defaults: [
            "autoDetectEnabled": true,
            "batteryFloor": 15
        ])
        if CommandLine.arguments.contains("--smoke") {
            AppModel.runSmokeAndExit()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-iconset"),
           CommandLine.arguments.indices.contains(index + 1) {
            do {
                try MarkRenderer.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                exit(0)
            } catch {
                print("icon render failed: \(error)")
                exit(1)
            }
        }
        // One instance only: a second launch must not create a second menu-bar
        // item or a second power controller.
        if let id = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != me }
            if !others.isEmpty { exit(0) }
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
