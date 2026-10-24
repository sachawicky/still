import Foundation

/// Plain-language description of the current state. No implementation terms.
public struct StatusSummary: Equatable, Sendable {
    public enum Tone: Sendable, Equatable { case idle, active, paused }

    public var tone: Tone
    public var title: String
    /// The reason: what is being kept alive.
    public var reason: String
    /// For how much longer, when that is a meaningful question.
    public var remaining: String?

    public static func make(
        decision: SessionDecision,
        restoring: Bool,
        streamName: String?,
        streamActive: Bool,
        agent: CodingAgent?,
        batteryFloor: Int,
        now: Date
    ) -> StatusSummary {
        if restoring {
            return StatusSummary(tone: .paused, title: "Restoring", reason: "Returning to normal sleep.", remaining: nil)
        }
        switch decision.phase {
        case .inactive:
            return StatusSummary(tone: .idle, title: "Inactive", reason: "Your Mac can sleep normally.", remaining: nil)
        case .suspended(let why):
            let reason: String
            switch why {
            case .battery: reason = "Battery is below \(batteryFloor)%. Resumes when plugged in."
            case .thermal: reason = "Your Mac is running hot. Resumes when it cools."
            case .lowPower: reason = "Low Power Mode is on."
            case .setup: reason = "One-time setup is needed."
            case .error: reason = "Sleep settings couldn’t be changed. Retrying."
            case .system: reason = "Released for sleep or screen lock. Start a new session to resume."
            case .externalDisplay: reason = "External display connected. macOS manages sleep."
            }
            return StatusSummary(tone: .paused, title: "Paused", reason: reason, remaining: nil)
        case .active:
            let reason: String
            var remaining: String?
            switch decision.context ?? .manual {
            case .streaming:
                reason = streamName.map { "Streaming to \($0)" } ?? "Streaming"
                remaining = streamActive ? "Until the stream ends" : "Stream ended. Releasing shortly."
            case .aiWork:
                reason = "\(agent?.rawValue ?? "Your coding agent") is working"
                remaining = agent != nil ? "Until the work finishes" : "Work finished. Releasing shortly."
            case .manual:
                reason = "Manual session"
                remaining = decision.deadline.map { Self.remainingText($0.timeIntervalSince(now)) } ?? "Until you turn it off"
            }
            // A manual timeout on top of an automatic session still ends it.
            if decision.context != .manual, let deadline = decision.deadline {
                remaining = Self.remainingText(deadline.timeIntervalSince(now))
            }
            return StatusSummary(tone: .active, title: "Active", reason: reason, remaining: remaining)
        }
    }

    public static func remainingText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total < 60 { return "Less than a minute remaining" }
        let minutes = (total + 59) / 60
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m remaining" }
        if m == 0 { return "\(h)h remaining" }
        return "\(h)h \(m)m remaining"
    }
}
