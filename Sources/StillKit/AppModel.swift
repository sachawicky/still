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
    @Published public private(set) var privilegeGranted = false
    @Published public private(set) var flagWarning: FlagWarning?
    @Published public private(set) var loginItemEnabled = false
    @Published public private(set) var loginItemNeedsApproval = false
    @Published public private(set) var loginItemNote: String?
    @Published public private(set) var setupInFlight = false
    @Published public private(set) var agent: CodingAgent?
    @Published public private(set) var streamActive = false
    @Published public private(set) var resumeNeedsPermission = false
    @Published public var showSettings = false

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

    public var phase: SessionPhase { decision.phase }

    /// True whenever a session is wanted or still being unwound.
    public var holdSwitchOn: Bool {
        policy.state.manualArmed || decision.autoArmed || decision.holdAwake || restoring
    }

    public init() {
        let autoDetect = defaults.object(forKey: "autoDetectEnabled") as? Bool ?? true
        let floor = defaults.object(forKey: "batteryFloor") as? Int ?? 15
        autoDetectEnabled = autoDetect
        aiDetectEnabled = defaults.object(forKey: "aiDetectEnabled") as? Bool ?? true
        resumePlaybackEnabled = defaults.object(forKey: "resumePlaybackEnabled") as? Bool ?? true
        safetyTimeout = SafetyTimeout(rawValue: defaults.object(forKey: "safetyTimeout") as? Int ?? SafetyTimeout.default.rawValue) ?? .default
        batteryFloor = floor
        showMenuBarWordmark = defaults.object(forKey: "showMenuBarWordmark") as? Bool ?? true

        // Restore a manual session only if its Safety Timeout has not passed.
        var restored = SessionState()
        if defaults.bool(forKey: "manualArmed") {
            let stored = defaults.object(forKey: "manualDeadline") as? Date
            if stored == nil || stored! > Date() {
                restored = SessionState(manualArmed: true, manualDeadline: stored)
            }
        }
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
        repairLoginItemLocation()
        refreshLoginItem()
        evaluate()
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

    public func setManualArmed(_ armed: Bool) {
        let snapshot = detection.snapshot()
        let deadline = armed ? safetyTimeout.deadline(from: Date()) : nil
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

    public func sleepNow() {
        setManualArmed(false)
        if appliedHold, !sleepController.writeSleepDisabled(false) {
            log.error("sleepNow: could not release SleepDisabled")
            return
        }
        if appliedHold {
            appliedHold = false
            assertion.setActive(false, reason: "")
            restoring = false
        }
        requestSystemSleep()
    }

    private func requestSystemSleep() {
        let result = ProcessRunner.run("/usr/bin/pmset", ["sleepnow"], timeout: 5)
        if result.exitCode <= 0 { return }
        log.info("pmset sleepnow failed, falling back to System Events")
        var error: NSDictionary?
        NSAppleScript(source: #"tell application "System Events" to sleep"#)?
            .executeAndReturnError(&error)
        if let error {
            log.error("sleep request failed: \(error)")
        }
    }

    public func beginSetup() {
        guard !setupInFlight, !privilegeGranted else { return }
        setupInFlight = true
        let granted = sleepController.installPrivilege()
        setupInFlight = false
        if granted {
            privilegeGranted = true
            reconcileOnLaunch()
            evaluate()
        }
    }

    public func restoreNormalSleep() {
        guard sleepController.writeSleepDisabled(false) else {
            if !privilegeGranted { beginSetup() }
            return
        }
        appliedHold = false
        assertion.setActive(false, reason: "")
        flagWarning = nil
        sleepController.didSetFlag = false
        evaluate()
    }

    public func removeAccess() {
        // Never remove the privilege while our own hold could still be in place:
        // without it the flag could not be cleared afterwards.
        let ownsFlag = sleepController.readSleepDisabled() == true && sleepController.didSetFlag
        if appliedHold || ownsFlag {
            guard sleepController.writeSleepDisabled(false) else { return }
            appliedHold = false
            assertion.setActive(false, reason: "")
            restoring = false
        }
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
        resumeNeedsPermission = resumePlaybackEnabled && !MediaKey.hasPermission
    }

    // MARK: - Core loop

    public func evaluate() {
        let snapshot = detection.snapshot()
        targets = snapshot.targets
        batteryPercent = snapshot.batteryPercent
        onBattery = snapshot.onBattery
        lidClosed = snapshot.lidClosed
        agent = snapshot.agent
        streamActive = snapshot.streamActive

        let input = SessionInput(
            now: Date(),
            manualArmed: policy.state.manualArmed,
            autoDetectEnabled: autoDetectEnabled,
            streamActive: snapshot.streamActive,
            batteryPercent: snapshot.batteryPercent < 0 ? 100 : snapshot.batteryPercent,
            onBattery: snapshot.onBattery,
            thermalNominalOrFair: snapshot.thermalNominalOrFair,
            lowPowerMode: snapshot.lowPowerMode,
            batteryFloor: batteryFloor,
            privilegeGranted: privilegeGranted,
            lastWriteSucceeded: sleepController.lastWriteSucceeded,
            aiDetectEnabled: aiDetectEnabled,
            agentActive: snapshot.agentActive
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
        if decision.holdAwake {
            flagWarning = nil
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
        if decision.holdAwake {
            guard privilegeGranted else { return }
            if !appliedHold {
                let ok = sleepController.writeSleepDisabled(true)
                appliedHold = ok
                assertion.setActive(ok, reason: "\(Brand.name): keeping the Mac active for a running session")
                if !ok {
                    log.error("failed to enable SleepDisabled")
                }
            }
        } else if appliedHold {
            let ok = sleepController.writeSleepDisabled(false)
            if ok {
                appliedHold = false
                assertion.setActive(false, reason: "")
                if sleepController.lastWriteSucceeded {
                    restoring = false
                }
            } else {
                restoring = true
            }
        } else {
            restoring = false
        }
    }

    // MARK: - Reconciliation

    private func reconcileOnLaunch() {
        let flag = sleepController.readSleepDisabled()
        let action = ReconcileLogic.launchAction(
            flag: flag,
            didSetFlag: sleepController.didSetFlag,
            privileged: privilegeGranted
        )
        switch action {
        case .clearFlag:
            if sleepController.writeSleepDisabled(false) {
                appliedHold = false
            }
        case .clearOwnership:
            sleepController.didSetFlag = false
        case .warnExternal:
            flagWarning = .external
        case .warnNoPrivilege:
            if flag == true {
                flagWarning = sleepController.didSetFlag ? .staleNoPrivilege : .external
            } else {
                sleepController.didSetFlag = false
            }
        case .none:
            break
        }
        if flag == true, appliedHold == false, sleepController.didSetFlag == false, flagWarning == nil {
            flagWarning = .external
        }
    }

    private func verifyTick() {
        evaluate()
        let flag = sleepController.readSleepDisabled()

        if decision.holdAwake {
            flagWarning = nil
            if flag == false, privilegeGranted {
                let ok = sleepController.writeSleepDisabled(true)
                appliedHold = ok
                assertion.setActive(ok, reason: "\(Brand.name): keeping the Mac active for a running session")
                if ok {
                    log.info("re-asserted SleepDisabled after external clear")
                }
            }
            return
        }

        if flag == true, sleepController.didSetFlag, privilegeGranted {
            if sleepController.writeSleepDisabled(false) {
                appliedHold = false
                assertion.setActive(false, reason: "")
                restoring = false
            } else {
                restoring = true
            }
        } else if flag == true, !sleepController.didSetFlag, flagWarning == nil {
            flagWarning = .external
        }
    }

    private func shutdown() {
        verifyTimer?.invalidate()
        deadlineTimer?.invalidate()
        resumeTimer?.invalidate()
        policy.setManualArmed(false, streamActive: false)
        Self.persist(policy.state, in: defaults)
        if appliedHold {
            _ = sleepController.writeSleepDisabled(false)
            appliedHold = false
        }
        assertion.setActive(false, reason: "")
        log.info("shutdown complete, SleepDisabled released")
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
