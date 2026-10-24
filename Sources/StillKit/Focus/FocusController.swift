import AppKit
import Combine
import CoreGraphics
import SwiftUI
import UserNotifications

@MainActor
public final class FocusController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published public var settings: FocusSettings {
        didSet {
            settings.save(defaults)
            if settings.nativeNotifications && !oldValue.nativeNotifications {
                requestNotifications()
            }
            if settings.guiAutomation { stop() }
            reconcileDisplays()
        }
    }
    public let appearance: AppearanceController
    @Published public private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published public private(set) var active = false
    @Published public private(set) var displays: [FocusDisplay] = []
    @Published public private(set) var pending: [FocusEvent] = []
    @Published public private(set) var note: String?
    @Published public private(set) var activity: String = "Background work continues"
    @Published public private(set) var renderingSuspended = false
    @Published public private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published public private(set) var thermal = ProcessInfo.processInfo.thermalState.rawValue
    @Published public private(set) var onBattery = false
    public func updatePower(onBattery: Bool) { self.onBattery = onBattery }
    public var onAutoActivate: (() -> Void)?
    private let defaults: UserDefaults
    private var windows: [String: NSWindow] = [:]
    private var attention = FocusAttentionState()
    private var eventFiles: [String: URL] = [:]
    private var loadedFiles: Set<URL> = []
    private var watcher: DispatchSourceFileSystemObject?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var sound: NSSound?
    private var systemSleeping = false
    private var screensSleeping = false

    public init(defaults: UserDefaults = .standard, appearance: AppearanceController? = nil, monitorInbox: Bool = true) {
        self.defaults = defaults
        self.appearance = appearance ?? AppearanceController(defaults: defaults)
        settings = FocusSettings.load(defaults)
        super.init()
        if Bundle.main.bundleURL.pathExtension == "app" {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.setNotificationCategories([UNNotificationCategory(identifier: "STILL_ATTENTION", actions: [
                UNNotificationAction(identifier: "STILL_RETURN", title: "Return to agent", options: [.foreground]),
                UNNotificationAction(identifier: "STILL_DISMISS", title: "Dismiss", options: [])
            ], intentIdentifiers: [])])
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileDisplays() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        // Local to Still: never reserves or intercepts a system-wide shortcut.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let covering = MainActor.assumeIsolated { self?.active == true }
            if covering && (event.keyCode == 53 || (event.charactersIgnoringModifiers == "." && event.modifierFlags.contains(.command))) {
                MainActor.assumeIsolated { self?.stop(animated: true) }
                return nil
            }
            return event
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                    self?.thermal = ProcessInfo.processInfo.thermalState.rawValue
                }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch name {
                    case NSWorkspace.willSleepNotification: self.systemSleeping = true
                    case NSWorkspace.didWakeNotification: self.systemSleeping = false
                    case NSWorkspace.screensDidSleepNotification: self.screensSleeping = true
                    case NSWorkspace.screensDidWakeNotification: self.screensSleeping = false
                    default: break
                    }
                    self.renderingSuspended = self.systemSleeping || self.screensSleeping
                }
            })
        }
        reconcileDisplays()
        if monitorInbox { startInbox() }
        if Bundle.main.bundleURL.pathExtension == "app" { refreshNotificationStatus() }
    }

    public func refreshNotificationStatus() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self?.notificationStatus = status }
        }
    }

    public static func runNotificationDiagnosticsAndExit() -> Never {
        print("Still native hook banners enabled: \(FocusSettings.load(.standard).nativeNotifications)")
        print("Notification values: authorization 0=undetermined 1=denied 2=authorized; settings 0=unsupported 1=disabled 2=enabled")
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            print("authorization=\(settings.authorizationStatus.rawValue) alerts=\(settings.alertSetting.rawValue) sounds=\(settings.soundSetting.rawValue) notificationCenter=\(settings.notificationCenterSetting.rawValue) alertStyle=\(settings.alertStyle.rawValue)")
            exit(0)
        }
        CFRunLoopRun()
        exit(1)
    }

    public static func enableNativeNotificationsAndExit() -> Never {
        do {
            try FocusSettings.enableNativeNotifications(in: .standard)
            guard UserDefaults.standard.synchronize() else {
                print("Could not persist notification opt-in")
                exit(1)
            }
        } catch {
            print("Could not enable notifications: \(error.localizedDescription)")
            exit(1)
        }
        // This is an explicit setup action, never an automatic launch request.
        // macOS retains control of the actual alert style and sound permission.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            print("Requested alert and sound authorization: granted=\(granted)")
            if let error { print("Authorization error: \(error.localizedDescription)") }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                print("authorization=\(settings.authorizationStatus.rawValue) alerts=\(settings.alertSetting.rawValue) sounds=\(settings.soundSetting.rawValue) notificationCenter=\(settings.notificationCenterSetting.rawValue) alertStyle=\(settings.alertStyle.rawValue)")
                exit(error == nil ? 0 : 1)
            }
        }
        CFRunLoopRun()
        exit(1)
    }
    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor in
                if error != nil { self?.note = "macOS could not enable notifications. Check notification settings." }
                self?.refreshNotificationStatus()
            }
        }
    }
    public func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?app.still.macos") { NSWorkspace.shared.open(url) }
    }
    isolated deinit {
        watcher?.cancel()
        sound?.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for window in windows.values { window.orderOut(nil); window.contentView = nil; window.close() }
    }

    public var canStart: Bool {
        !settings.guiAutomation && !FocusDisplayPolicy.selected(displays, preference: settings.displays).isEmpty
    }
    public func pause(reason: String) { stop(); note = reason }
    public func start() {
        guard !settings.guiAutomation else {
            note = "Focus is paused for foreground GUI automation. Turn it off in Focus settings when finished."
            return
        }
        guard !FocusDisplayPolicy.selected(displays, preference: settings.displays).isEmpty else {
            note = "Choose a connected display in Focus settings."
            return
        }
        note = nil
        active = true
        reconcileDisplays()
        // Gives Escape a reliable local target without an Accessibility/global event tap.
        NSApp.activate(ignoringOtherApps: true)
        windows.values.first?.makeKeyAndOrderFront(nil)
    }
    public func stop(animated: Bool = false) {
        active = false
        let closing = Array(windows.values)
        windows.removeAll()
        for window in closing {
            // Exit is synchronous: no fading transparent window can intercept
            // the next click, even when the main run loop is busy.
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }
    public func updateActivity(_ agent: CodingAgent?) {
        activity = agent.map { "\($0.rawValue) · recent session activity" } ?? "Background work continues"
    }
    public func selectDisplay(_ id: String, enabled: Bool) {
        var selection = FocusDisplayPolicy.selected(displays, preference: settings.displays)
        if enabled { selection.insert(id) } else { selection.remove(id) }
        settings.displays = selection.sorted()
    }
    private func screenID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func reconcileDisplays() {
        let screens = NSScreen.screens.compactMap { screen -> (String, NSScreen)? in
            screenID(screen).map { ($0, screen) }
        }
        displays = screens.map { id, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return FocusDisplay(id: id, name: screen.localizedName, builtIn: CGDisplayIsBuiltin(number?.uint32Value ?? 0) != 0)
        }
        let selected = FocusDisplayPolicy.selected(displays, preference: settings.displays)
        for id in Array(windows.keys) where !active || !selected.contains(id) {
            if let window = windows.removeValue(forKey: id) { window.contentView = nil; window.close() }
        }
        guard active else { return }
        guard !selected.isEmpty else {
            stop(); note = "Focus stopped because its displays disconnected."
            return
        }
        for (id, screen) in screens where selected.contains(id) {
            if let window = windows[id] { window.setFrame(screen.frame, display: true); continue }
            let window = FocusWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.onExit = { [weak self] in self?.stop() }
            window.isReleasedWhenClosed = false
            window.level = .floating // Below the menu bar, system security UI and screen lock.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.contentView = NSHostingView(rootView: FocusAmbientView().environmentObject(self).environmentObject(appearance))
            windows[id] = window
            window.orderFrontRegardless()
        }
    }
    private func startInbox() {
        do {
            try FocusInbox.prepare()
            let fd = open(FocusInbox.directory.path, O_EVTONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readInbox() } }
            source.setCancelHandler { close(fd) }
            watcher = source
            source.resume()
            readInbox(restoring: true)
        } catch { note = "Agent notifications are unavailable: the local inbox could not be opened." }
    }
    private func readInbox(restoring: Bool = false) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: FocusInbox.directory, includingPropertiesForKeys: nil) else { return }
        loadedFiles.formIntersection(files)
        let events = files.prefix(1024).filter { !loadedFiles.contains($0) }.compactMap { url in
            FocusInbox.read(url).map { (url, $0) }
        }.sorted { $0.1.date < $1.1.date }
        for (url, event) in events {
            loadedFiles.insert(url)
            if event.kind.needsAttention {
                if attention.insert(event) {
                    eventFiles[event.id] = url
                    pending = attention.pending
                    // Restored requests stay visible but do not replay old sounds.
                    if !restoring && Date().timeIntervalSince(event.date) < 30 { alert(event) }
                } else { try? FileManager.default.removeItem(at: url) }
            } else {
                switch event.kind {
                case .started:
                    if settings.autoActivate && Date().timeIntervalSince(event.date) < 30 { onAutoActivate?() }
                case .guiBegin: settings.guiAutomation = true; stop()
                case .guiEnd: settings.guiAutomation = false
                default: break
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    private func alert(_ event: FocusEvent) {
        if settings.sound != "None", let value = NSSound(named: NSSound.Name(settings.sound))?.copy() as? NSSound {
            sound = value; value.volume = Float(min(1, max(0, settings.volume))); value.play()
        }
        if settings.nativeNotifications {
            let content = UNMutableNotificationContent()
            content.categoryIdentifier = "STILL_ATTENTION"
            content.threadIdentifier = event.provider.rawValue
            content.title = "\(event.provider.name) needs attention"
            content.body = "\(event.project) · \(event.kind.context)"
            content.userInfo = ["focusEventID": event.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }
    public func dismiss(_ event: FocusEvent) {
        if let url = eventFiles[event.id] {
            do { try FileManager.default.removeItem(at: url) }
            catch { note = "Could not dismiss this request. Try again."; return }
        }
        eventFiles.removeValue(forKey: event.id)
        attention.dismiss(event.id); pending = attention.pending
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [event.id])
    }
    public func returnToAgent(_ event: FocusEvent) {
        stop(animated: true)
        let allowed = ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.mitchellh.ghostty"]
        if let target = event.target, allowed.contains(target),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: target).first {
            app.activate(); return
        }
        note = "Focus ended. Switch to the \(event.provider.name) session in your terminal or app; the request stays until dismissed."
    }
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["focusEventID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            if let self, let event = self.pending.first(where: { $0.id == id }) {
                if action == "STILL_DISMISS" { self.dismiss(event) }
                else if action != UNNotificationDismissActionIdentifier { self.returnToAgent(event) }
            }
        }
        completionHandler()
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Native banners also appear while Still owns the key Focus window.
        // Hook sounds are played once by alert(), never by the notification too.
        completionHandler([.banner, .list])
    }
}

private final class FocusWindow: NSWindow {
    var onExit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // The ambient cover has no interactive controls (agent actions live
        // in the Still menu). Consume its first click even when Still is not
        // active, rather than forwarding an activation click to another app.
        if event.type == .leftMouseDown {
            onExit?()
            return
        }
        super.sendEvent(event)
    }
}
