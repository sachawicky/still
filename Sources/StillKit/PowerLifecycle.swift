import Foundation

/// Safety interruptions latch until a new explicit user action. Unlocking,
/// waking, detector callbacks and display changes cannot silently re-arm Still.
public struct PowerLifecycle: Equatable, Sendable {
    public enum Event: Sendable {
        case lock, sessionInactive, sleepRequested, willSleep, didWake, terminate
    }
    public enum State: Equatable, Sendable {
        case ready, locked, sessionInactive, sleepRequested, sleeping, awaitingResume, terminated
    }
    public private(set) var state: State = .ready
    public init() {}
    public var allowsHold: Bool { state == .ready }
    public mutating func receive(_ event: Event) {
        guard state != .terminated else { return }
        switch event {
        case .lock: state = .locked
        case .sessionInactive: state = .sessionInactive
        case .sleepRequested: state = .sleepRequested
        case .willSleep: state = .sleeping
        case .didWake: state = .awaitingResume
        case .terminate: state = .terminated
        }
    }
    public mutating func sessionBecameActive() {
        if state == .locked || state == .sessionInactive { state = .awaitingResume }
    }
    public mutating func resumeByUser() {
        if state == .awaitingResume || state == .sleepRequested { state = .ready }
    }
}
