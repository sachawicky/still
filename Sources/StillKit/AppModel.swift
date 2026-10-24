import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications
import os.log

@MainActor
public final class AppModel: ObservableObject {
    public enum FlagWarning: Equatable {
        case external
        case staleNoPrivilege
    }

    @Published public private(set) var decision = SessionDecision(
        phase: .inactive, holdAwake: false, autoArmed: false, inGrace: false
    )
    @Published public private(set) var appliedHold = false
    @Published public private(set) var restoring = false
    @Published public private(set) var targets: [StreamTarget] = []
    @Published public private(set) var batteryPercent = -1
    @Published public private(set) var onBattery = false
    @Published public private(set) var lidClosed = false
    @Published public private(set) var externalDisplayConnected = false
    @Published public private(set) var powerLifecycle = PowerLifecycle()
    @Published public private(set) var privilegeGranted = false
    @Published public private(set) var flagWarning: FlagWarning?
    @Published public private(set) var loginItemEnabled = false
    @Published public private(set) var loginItemNeedsApproval = false
    @Published public private(set) var loginItemNote: String?
    @Published public private(set) var setupInFlight = false
    @Published public private(set) var setupNote: String?
    @Published public private(set) var agent: CodingAgent?
    @Published public private(set) var streamActive = false
    @Published public private(set) var resumeNeedsPermission = false
    @Published public var showSettings = false
    @Published public var showWelcome = false
    @Published public private(set) var actionNote: String?

    @Published public var aiDetectEnabled: Bool {
        didSet {
            defaults.set(aiDetectEnabled, forKey: "aiDetectEnabled")
            evaluate()
        }
    }

    @Published public var resumePlaybackEnabled: Bool {
        didSet {
            defaults.set(resumePlaybackEnabled, forKey: "resumePlaybackEnabled")
            if resumePlaybackEnabled { requestResumePermissionIfNeeded(force: true) }
            evaluate()
        }
    }

    @Published public var showMenuBarWordmark: Bool {
        didSet { defaults.set(showMenuBarWordmark, forKey: "showMenuBarWordmark") }
    }

    @Published public var safetyTimeout: SafetyTimeout {
        didSet { defaults.set(safetyTimeout.rawValue, forKey: "safetyTimeout") }
    }

    @Published public var autoDetectEnabled: Bool {
        didSet {
            defaults.set(autoDetectEnabled, forKey: "autoDetectEnabled")
            evaluate()
        }
    }

    @Published public var batteryFloor: Int {
        didSet {
            defaults.set(batteryFloor, forKey: "batteryFloor")
            evaluate()
        }
    }

    public let appearance = AppearanceController()
    public let focus: FocusController

    private var policy: SessionPolicy
    private let sleepController = SleepController()
    private let detection = DetectionCenter()
    private let assertion = AssertionController()
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: Brand.logSubsystem, category: "model")
    private var verifyTimer: Timer?
    private var deadlineTimer: Timer?
    private var resumeTimer: Timer?
    private var resumeLogic = PlaybackResumeLogic()
    private var wasHolding = false
    private var powerObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var assertionHealthy = true

    public var phase: SessionPhase { decision.phase }
    public var effectiveBatteryFloor: Int { max(15, batteryFloor) }

    private func safeDeadline() -> Date {
        Date().addingTimeInterval(min(safetyTimeout.interval ?? 3 * 3600, 3 * 3600))
    }

    /// True whenever a session is wanted or still being unwound.
    public var holdSwitchOn: Bool {
        policy.state.manualArmed || decision.autoArmed || decision.holdAwake || restoring
    }

    public init() {
        PreferenceMigration.migrate(defaults)
        focus = FocusController(appearance: appearance)
        appearance.useForApplication()
        showWelcome = !defaults.bool(forKey: "stillWelcome.v2")
        let autoDetect = defaults.object(forKey: "autoDetectEnabled") as? Bool ?? false
        let floor = defaults.object(forKey: "batteryFloor") as? Int ?? 15
        autoDetectEnabled = autoDetect
        aiDetectEnabled = defaults.object(forKey: "aiDetectEnabled") as? Bool ?? false
        resumePlaybackEnabled = defaults.object(forKey: "resumePlaybackEnabled") as? Bool ?? false
        safetyTimeout = SafetyTimeout(rawValue: defaults.object(forKey: "safetyTimeout") as? Int ?? SafetyTimeout.default.rawValue) ?? .default
        batteryFloor = floor
        showMenuBarWordmark = defaults.object(forKey: "showMenuBarWordmark") as? Bool ?? false

        // A restarted process must never resurrect an old manual awake session.
        let restored = SessionState()
        policy = SessionPolicy(state: restored)
        Self.persist(restored, in: defaults)

        privilegeGranted = sleepController.privilegeGranted

        detection.onChange = { [weak self] in
            self?.evaluate()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLoginItem()
                self?.refreshPermissions()
            }
        }

        reconcileOnLaunch()
        observePowerLifecycle()
        repairLoginItemLocation()
        refreshLoginItem()
        focus.onAutoActivate = { [weak self] in self?.startFocus(userInitiated: false) }
        evaluate()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.showWelcome else { return }
            WelcomeWindow.show(appearance: self.appearance) { [weak self] in self?.completeWelcome() }
        }
        log.info("started (privilege=\(self.privilegeGranted, privacy: .public))")

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.verifyTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        verifyTimer = timer
    }

    // MARK: - User actions

    public func completeWelcome() {
        defaults.set(true, forKey: "stillWelcome.v2")
        showWelcome = false
    }

    public func setManualArmed(_ armed: Bool) {
        actionNote = nil
        if armed { powerLifecycle.resumeByUser(); assertionHealthy = true }
        let snapshot = detection.snapshot()
        let deadline = armed ? safeDeadline() : nil
        policy.setManualArmed(armed, streamActive: snapshot.streamActive, agentActive: snapshot.agentActive, deadline: deadline)
        Self.persist(policy.state, in: defaults)
        if armed { Notifier.requestAuthorizationIfNeeded() }
        evaluate()
    }

    private static func persist(_ state: SessionState, in defaults: UserDefaults) {
        defaults.set(state.manualArmed, forKey: "manualArmed")
        if let deadline = state.manualDeadline {
            defaults.set(deadline, forKey: "manualDeadline")
        } else {
            defaults.removeObject(forKey: "manualDeadline")
        }
    }

    /// Focus uses the same policy and guards as every existing session. A newly
    /// requested Focus hold is always finite, even if the manual picker says unlimited.
    public func startFocus() {
        startFocus(userInitiated: true)
    }

    private func startFocus(userInitiated: Bool) {
        guard !focus.settings.guiAutomation else { return }
        if userInitiated {
            powerLifecycle.resumeByUser()
            assertionHealthy = true
        }
        guard powerLifecycle.allowsHold else { return }
        guard focus.canStart else { focus.start(); return }
        if DetectionCenter.hasExternalDisplay() {
            evaluate()
            focus.start()
            return
        }
        if !decision.holdAwake {
            let snapshot = detection.snapshot()
            policy.setManualArmed(true, streamActive: snapshot.streamActive, agentActive: snapshot.agentActive,
                                  deadline: safeDeadline())
            Self.persist(policy.state, in: defaults)
            evaluate()
        }
        guard decision.holdAwake, appliedHold else {
            focus.pause(reason: "Still cannot keep your Mac active. Check its session status and safety settings.")
            return
        }
        focus.start()
    }

    public func sleepNow() {
        interruptPower(.sleepRequested)
        guard !restoring else { return }
        requestSystemSleep()
    }

    private func requestSystemSleep() {
        let result = ProcessRunner.run("/usr/bin/pmset", ["sleepnow"], timeout: 5)
        if result.exitCode == 0 { return }
        log.info("pmset sleepnow failed, falling back to System Events")
        var error: NSDictionary?
        NSAppleScript(source: #"tell application "System Events" to sleep"#)?
            .executeAndReturnError(&error)
        if let error {
            actionNote = "macOS could not start sleep. End the session and use the Apple menu to sleep."
            log.error("sleep request failed: \(error)")
        }
    }

    public func beginSetup() {
        // Only recover an owned legacy setting. New sessions need no privilege.
        guard sleepController.didSetFlag else { return }
        setupInFlight = true
        let restored = sleepController.restoreLegacyWithAuthorization()
        setupInFlight = false
        setupNote = restored ? nil : "Normal sleep could not be restored. Approve the one-time recovery and retry."
        retryLegacyRestoration()
        evaluate()
    }

    public func restoreNormalSleep() {
        interruptPower(.sleepRequested)
    }

    public func removeAccess() {
        // Do not remove the old permission before its owned global flag is clear.
        retryLegacyRestoration()
        guard !sleepController.didSetFlag else { return }
        sleepController.removePrivilege()
        privilegeGranted = sleepController.privilegeGranted
        evaluate()
    }

    public func setLoginItem(_ enabled: Bool) {
        let service = SMAppService.mainApp
        loginItemNote = nil
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            log.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            loginItemNote = "Couldn’t change this. Try again from the Applications folder."
        }
        refreshLoginItem()
    }

    /// A login item registered from another copy (e.g. a development build) would
    /// launch that copy. When running from /Applications, re-register this one.
    private func repairLoginItemLocation() {
        let service = SMAppService.mainApp
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), service.status == .enabled else { return }
        do {
            try service.unregister()
            try service.register()
        } catch {
            log.error("login item re-register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mirrors the real registration state, not a stored preference.
    public func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginItemEnabled = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
        if status == .requiresApproval {
            loginItemNote = "Approve \(Brand.name) in System Settings."
        } else if loginItemNote == "Approve \(Brand.name) in System Settings." {
            loginItemNote = nil
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Re-reads permissions the user may have changed in System Settings.
    public func refreshPermissions() {
        privilegeGranted = sleepController.privilegeGranted
        resumeNeedsPermission = resumePlaybackEnabled && !MediaKey.hasPermission
    }

    // MARK: - Core loop

    public func evaluate() {
        let snapshot = detection.snapshot()
        targets = snapshot.targets
        batteryPercent = snapshot.batteryPercent
        onBattery = snapshot.onBattery
        lidClosed = snapshot.lidClosed
        externalDisplayConnected = snapshot.externalDisplayConnected
        agent = snapshot.agent
        streamActive = snapshot.streamActive

        let input = SessionInput(
            now: Date(),
            manualArmed: policy.state.manualArmed,
            autoDetectEnabled: autoDetectEnabled,
            streamActive: snapshot.streamActive,
            batteryPercent: snapshot.batteryPercent < 0 ? 0 : snapshot.batteryPercent,
            onBattery: snapshot.onBattery,
            thermalNominalOrFair: snapshot.thermalNominalOrFair,
            lowPowerMode: snapshot.lowPowerMode,
            batteryFloor: effectiveBatteryFloor,
            privilegeGranted: true, // native assertions require no administrator access
            lastWriteSucceeded: assertionHealthy && !restoring,
            aiDetectEnabled: aiDetectEnabled,
            agentActive: snapshot.agentActive,
            systemAllowsHold: powerLifecycle.allowsHold,
            externalDisplayConnected: snapshot.externalDisplayConnected
        )

        decision = policy.step(input)
        if decision.expired {
            Self.persist(policy.state, in: defaults)
            Notifier.post(
                title: "\(Brand.name) released your Mac",
                body: "The safety timeout ended. Normal sleep is back."
            )
        }
        apply(decision)
        focus.updatePower(onBattery: onBattery)
        focus.updateActivity(agent)
        if focus.active && !externalDisplayConnected && (!decision.holdAwake || !appliedHold) {
            focus.pause(reason: "Focus ended with Still’s awake session. Check its status before restarting.")
        }
        scheduleDeadlineTimer()
        updateResumeMonitoring(snapshotStream: snapshot.streamActive)
    }

    // MARK: - Safety Timeout

    private func scheduleDeadlineTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard policy.state.manualArmed, let deadline = policy.state.manualDeadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    // MARK: - Lid-close playback resume

    private func requestResumePermissionIfNeeded(force: Bool = false) {
        resumeNeedsPermission = resumePlaybackEnabled && !MediaKey.hasPermission
        guard resumeNeedsPermission else { return }
        if force || !defaults.bool(forKey: "askedPostEventAccess") {
            defaults.set(true, forKey: "askedPostEventAccess")
            MediaKey.requestPermission()
        }
    }

    public func openAccessibilitySettings() {
        MediaKey.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateResumeMonitoring(snapshotStream: Bool) {
        let wanted = resumePlaybackEnabled && decision.holdAwake && (snapshotStream || decision.inGrace)
        if wanted, !wasHolding { requestResumePermissionIfNeeded() }
        wasHolding = wanted
        if wanted {
            guard resumeTimer == nil else { return }
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeTick() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            resumeTimer = timer
        } else {
            resumeTimer?.invalidate()
            resumeTimer = nil
            resumeLogic.reset()
        }
    }

    private func resumeTick() {
        let playing = MediaKey.safariIsRunning() && detection.browserPlaybackActive()
        let send = resumeLogic.observe(
            now: Date(),
            lidClosed: detection.lidIsClosed(),
            holding: appliedHold,
            streamActive: true,
            playing: playing
        )
        guard send else { return }
        if MediaKey.sendPlay() {
            log.info("sent one Play command after lid close")
        } else {
            resumeNeedsPermission = true
        }
    }

    private func apply(_ decision: SessionDecision) {
        let wanted = decision.holdAwake && powerLifecycle.allowsHold && !externalDisplayConnected && !restoring
        let ok = assertion.setActive(wanted, reason: "Still: awake session; explicit sleep always allowed")
        appliedHold = assertion.isActive
        assertionHealthy = assertionHealthy && ok
        if !ok { actionNote = "Still could not update its awake assertion. End the session and try again." }
    }

    // MARK: - Reconciliation

    private func reconcileOnLaunch() {
        retryLegacyRestoration()
    }

    private func retryLegacyRestoration() {
        let flag = sleepController.readSleepDisabled()
        if sleepController.didSetFlag {
            if flag == false {
                sleepController.didSetFlag = false
                restoring = false
                flagWarning = nil
            } else {
                restoring = !sleepController.writeSleepDisabled(false)
                flagWarning = restoring ? .staleNoPrivilege : nil
            }
        } else {
            restoring = false
            flagWarning = flag == true ? .external : nil
        }
    }

    private func observePowerLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, PowerLifecycle.Event)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
            (NSWorkspace.willPowerOffNotification, .terminate),
            // Conservative public fallback for lock detection: display sleep
            // also ends the session; it is never interpreted as an immediate
            // request to put the machine to sleep.
            (NSWorkspace.screensDidSleepNotification, .sessionInactive)
        ]
        for (name, event) in events {
            powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interruptPower(event) }
            })
        }
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptPower(.didWake) }
        })
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.powerLifecycle.sessionBecameActive()
                    self?.evaluate()
                }
            })
        }
        // macOS emits this distributed notification on lock, but does not
        // document it as a public contract. It supplements the public session
        // and display-sleep paths above; never use it to intercept Apple Sleep.
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptPower(.lock) }
        }
    }

    private func interruptPower(_ event: PowerLifecycle.Event) {
        powerLifecycle.receive(event) // latch BEFORE releasing any resources
        _ = assertion.setActive(false, reason: "")
        appliedHold = assertion.isActive
        focus.stop()
        resumeTimer?.invalidate()
        resumeTimer = nil
        resumeLogic.reset()
        policy = SessionPolicy() // discard automatic trackers and grace windows
        Self.persist(policy.state, in: defaults)
        retryLegacyRestoration()
        evaluate()
    }

    isolated deinit {
        verifyTimer?.invalidate()
        deadlineTimer?.invalidate()
        resumeTimer?.invalidate()
        for observer in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    }

    private func verifyTick() {
        retryLegacyRestoration()
        refreshPermissions()
        evaluate()
    }

    private func shutdown() {
        interruptPower(.terminate)
        verifyTimer?.invalidate()
        deadlineTimer?.invalidate()
        resumeTimer?.invalidate()
        policy.setManualArmed(false, streamActive: false)
        Self.persist(policy.state, in: defaults)
        log.info("shutdown complete; owned resources released or restoration warning retained")
    }

    // MARK: - Smoke mode (read-only diagnostics)

    public static func runSmokeAndExit() -> Never {
        let controller = SleepController()
        let detection = DetectionCenter()
        let snapshot = detection.snapshot()
        print("\(Brand.name) smoke test")
        print("  user: \(CurrentUser.shortName)")
        print("  privilege: \(controller.privilegeGranted)")
        print("  SleepDisabled: \(controller.readSleepDisabled().map(String.init(describing:)) ?? "unknown")")
        print("  login item: \(SMAppService.mainApp.status)")
        print("  accessibility (post events): \(MediaKey.hasPermission)")
        print("  didSetFlag: \(controller.didSetFlag)")
        print("  stream targets: \(snapshot.targets.map { "\($0.kind.rawValue)=\($0.name)" }.joined(separator: ", "))")
        print("  battery: \(snapshot.batteryPercent)% onBattery=\(snapshot.onBattery)")
        print("  agent working: \(snapshot.agent?.rawValue ?? "none")")
        print("  thermalOK=\(snapshot.thermalNominalOrFair) lowPower=\(snapshot.lowPowerMode) lidClosed=\(snapshot.lidClosed)")
        exit(0)
    }
}

@MainActor
enum Notifier {
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorizationIfNeeded() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
