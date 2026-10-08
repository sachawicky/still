import Foundation

public enum SuspendReason: String, Sendable, Equatable {
    case battery
    case thermal
    case lowPower
    case setup
    case error
}

public enum SessionPhase: Sendable, Equatable {
    case active
    case inactive
    case suspended(SuspendReason)
}

/// Why the Mac is being kept active. Contexts share one behavior; they only
/// differ in how the session started and what the UI says about it.
public enum SessionContext: String, Sendable, Equatable {
    case streaming
    case aiWork
    case manual
}

/// How long a manual session may run before the hold is released automatically.
public enum SafetyTimeout: Int, CaseIterable, Sendable, Identifiable {
    case oneHour = 1
    case twoHours = 2
    case threeHours = 3
    case sixHours = 6
    case untilDisabled = 0

    public static let `default`: SafetyTimeout = .threeHours

    public var id: Int { rawValue }

    public var interval: TimeInterval? {
        self == .untilDisabled ? nil : TimeInterval(rawValue) * 3600
    }

    public var label: String {
        switch self {
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .threeHours: return "3 hours"
        case .sixHours: return "6 hours"
        case .untilDisabled: return "Until I turn it off"
        }
    }

    public func deadline(from start: Date) -> Date? {
        interval.map { start.addingTimeInterval($0) }
    }
}

public struct SessionInput: Sendable, Equatable {
    public var now: Date
    public var manualArmed: Bool
    public var autoDetectEnabled: Bool
    public var streamActive: Bool
    public var batteryPercent: Int
    public var onBattery: Bool
    public var thermalNominalOrFair: Bool
    public var lowPowerMode: Bool
    public var batteryFloor: Int
    public var privilegeGranted: Bool
    public var lastWriteSucceeded: Bool
    public var aiDetectEnabled: Bool
    public var agentActive: Bool

    public init(
        now: Date,
        manualArmed: Bool,
        autoDetectEnabled: Bool,
        streamActive: Bool,
        batteryPercent: Int,
        onBattery: Bool,
        thermalNominalOrFair: Bool,
        lowPowerMode: Bool,
        batteryFloor: Int,
        privilegeGranted: Bool,
        lastWriteSucceeded: Bool,
        aiDetectEnabled: Bool = false,
        agentActive: Bool = false
    ) {
        self.now = now
        self.manualArmed = manualArmed
        self.autoDetectEnabled = autoDetectEnabled
        self.streamActive = streamActive
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.thermalNominalOrFair = thermalNominalOrFair
        self.lowPowerMode = lowPowerMode
        self.batteryFloor = batteryFloor
        self.privilegeGranted = privilegeGranted
        self.lastWriteSucceeded = lastWriteSucceeded
        self.aiDetectEnabled = aiDetectEnabled
        self.agentActive = agentActive
    }
}

public struct SessionDecision: Sendable, Equatable {
    public var phase: SessionPhase
    public var holdAwake: Bool
    public var autoArmed: Bool
    public var inGrace: Bool
    /// The context to show while a session is wanted (even if suspended).
    public var context: SessionContext?
    /// When the manual Safety Timeout fires, if one is running.
    public var deadline: Date?
    /// True for exactly one step when a timeout released the hold.
    public var expired: Bool

    public init(
        phase: SessionPhase,
        holdAwake: Bool,
        autoArmed: Bool,
        inGrace: Bool,
        context: SessionContext? = nil,
        deadline: Date? = nil,
        expired: Bool = false
    ) {
        self.phase = phase
        self.holdAwake = holdAwake
        self.autoArmed = autoArmed
        self.inGrace = inGrace
        self.context = context
        self.deadline = deadline
        self.expired = expired
    }
}

/// Tracks one automatically detected activity (a stream, a coding agent).
struct AutoTracker: Sendable, Equatable {
    var sawActive = false
    var suppressed = false
    var graceDeadline: Date?
    var armedSince: Date?

    struct Result { var armed: Bool; var inGrace: Bool; var ceilingHit: Bool }

    mutating func step(active: Bool, enabled: Bool, now: Date, grace: TimeInterval, ceiling: TimeInterval) -> Result {
        if active {
            sawActive = true
            graceDeadline = nil
        } else if suppressed {
            suppressed = false
            graceDeadline = now
        } else if sawActive, graceDeadline == nil {
            graceDeadline = now.addingTimeInterval(grace)
        }

        let inGrace: Bool = {
            if active { return true }
            guard let deadline = graceDeadline else { return false }
            return now < deadline
        }()

        var armed = enabled && !suppressed && sawActive && inGrace
        var ceilingHit = false
        if armed {
            let since = armedSince ?? now
            armedSince = since
            if now.timeIntervalSince(since) >= ceiling {
                suppressed = true
                armed = false
                armedSince = nil
                ceilingHit = true
            }
        } else {
            armedSince = nil
        }
        return Result(armed: armed, inGrace: inGrace && enabled, ceilingHit: ceilingHit)
    }

    mutating func suppress(whileActive active: Bool) {
        if active { suppressed = true }
    }
}

public struct SessionState: Sendable, Equatable {
    public var manualArmed: Bool
    public var manualDeadline: Date?

    public init(manualArmed: Bool = false, manualDeadline: Date? = nil) {
        self.manualArmed = manualArmed
        self.manualDeadline = manualDeadline
    }
}

public struct SessionPolicy: Sendable, Equatable {
    public var state: SessionState
    public var graceInterval: TimeInterval
    /// Hard ceiling for any automatically detected session, a backstop against
    /// a stuck detector. Not user-visible.
    public var autoCeiling: TimeInterval

    private var stream = AutoTracker()
    private var agent = AutoTracker()

    public init(
        state: SessionState = SessionState(),
        graceInterval: TimeInterval = 15,
        autoCeiling: TimeInterval = 8 * 3600
    ) {
        self.state = state
        self.graceInterval = graceInterval
        self.autoCeiling = autoCeiling
    }

    public mutating func setManualArmed(
        _ armed: Bool,
        streamActive: Bool,
        agentActive: Bool = false,
        deadline: Date? = nil
    ) {
        state.manualArmed = armed
        state.manualDeadline = armed ? deadline : nil
        if armed {
            stream.suppressed = false
            agent.suppressed = false
        } else {
            stream.suppress(whileActive: streamActive)
            agent.suppress(whileActive: agentActive)
        }
    }

    public mutating func step(_ input: SessionInput) -> SessionDecision {
        var expired = false
        if state.manualArmed, let deadline = state.manualDeadline, input.now >= deadline {
            state.manualArmed = false
            state.manualDeadline = nil
            stream.suppress(whileActive: input.streamActive)
            agent.suppress(whileActive: input.agentActive)
            expired = true
        }

        let s = stream.step(
            active: input.streamActive, enabled: input.autoDetectEnabled,
            now: input.now, grace: graceInterval, ceiling: autoCeiling
        )
        let a = agent.step(
            active: input.agentActive, enabled: input.aiDetectEnabled,
            now: input.now, grace: graceInterval * 2, ceiling: autoCeiling
        )
        if s.ceilingHit || a.ceilingHit { expired = true }

        let manual = state.manualArmed
        let autoArmed = !manual && (s.armed || a.armed)
        let desired = manual || s.armed || a.armed
        let inGrace = s.inGrace || a.inGrace

        let context: SessionContext? = {
            guard desired else { return nil }
            if s.armed { return .streaming }
            if a.armed { return .aiWork }
            return .manual
        }()
        let deadline = manual ? state.manualDeadline : nil

        func decision(_ phase: SessionPhase, hold: Bool) -> SessionDecision {
            SessionDecision(
                phase: phase, holdAwake: hold, autoArmed: autoArmed, inGrace: inGrace,
                context: context, deadline: deadline, expired: expired
            )
        }

        guard desired else {
            return SessionDecision(
                phase: .inactive, holdAwake: false, autoArmed: false,
                inGrace: false, expired: expired
            )
        }
        if !input.privilegeGranted { return decision(.suspended(.setup), hold: false) }
        if !input.lastWriteSucceeded { return decision(.suspended(.error), hold: false) }
        if input.lowPowerMode { return decision(.suspended(.lowPower), hold: false) }
        if !input.thermalNominalOrFair { return decision(.suspended(.thermal), hold: false) }
        if input.onBattery, input.batteryPercent < input.batteryFloor {
            return decision(.suspended(.battery), hold: false)
        }
        return decision(.active, hold: true)
    }
}

public enum LaunchAction: String, Sendable, Equatable {
    case clearFlag
    case clearOwnership
    case warnExternal
    case warnNoPrivilege
    case none
}

public enum ReconcileLogic {
    public static func launchAction(flag: Bool?, didSetFlag: Bool, privileged: Bool) -> LaunchAction {
        guard let flag else { return didSetFlag ? .clearOwnership : .none }
        if flag {
            if didSetFlag {
                return privileged ? .clearFlag : .warnNoPrivilege
            }
            return privileged ? .warnExternal : .warnNoPrivilege
        }
        return didSetFlag ? .clearOwnership : .none
    }

    public static func tickAction(
        flag: Bool?,
        holdDesired: Bool,
        didSetFlag: Bool,
        privileged: Bool
    ) -> ReconcileAction? {
        guard let flag else { return nil }
        if holdDesired, !flag, privileged { return .setFlag(true) }
        if !holdDesired, flag, didSetFlag, privileged { return .setFlag(false) }
        return nil
    }
}

public enum ReconcileAction: Sendable, Equatable {
    case setFlag(Bool)
}
