import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Decides when to press Play once after the lid closes.
///
/// WebKit pauses HTML5 media when it sees a system-sleep interruption during the
/// clamshell transition, even though the Mac stays awake. We only resume when
/// playback was demonstrably running just before the lid closed, and never more
/// than twice (one try, one retry) per lid close.
public struct PlaybackResumeLogic: Sendable, Equatable {
    public var settleDelay: TimeInterval = 4
    public var retryDelay: TimeInterval = 8
    public var cooldown: TimeInterval = 120
    /// Playback must have been seen this recently before the lid closed.
    public var recentWindow: TimeInterval = 4

    private var lastPlayingAt: Date?
    private var closedAt: Date?
    private var armed = false
    private var attempts = 0
    private var lastAttemptAt: Date?

    public init() {}

    public mutating func reset() {
        lastPlayingAt = nil
        closedAt = nil
        armed = false
        attempts = 0
    }

    /// Returns true when a single Play command should be sent now.
    public mutating func observe(
        now: Date,
        lidClosed: Bool,
        holding: Bool,
        streamActive: Bool,
        playing: Bool
    ) -> Bool {
        guard holding, streamActive else {
            reset()
            return false
        }
        if !lidClosed {
            if playing { lastPlayingAt = now }
            closedAt = nil
            armed = false
            attempts = 0
            return false
        }
        if closedAt == nil {
            closedAt = now
            let wasPlaying = lastPlayingAt.map { now.timeIntervalSince($0) <= recentWindow } ?? false
            let cooled = lastAttemptAt.map { now.timeIntervalSince($0) >= cooldown } ?? true
            armed = wasPlaying && cooled
            attempts = 0
        }
        guard armed, let closedAt else { return false }
        if playing {
            armed = false
            return false
        }
        if attempts == 0, now.timeIntervalSince(closedAt) >= settleDelay {
            attempts = 1
            lastAttemptAt = now
            return true
        }
        if attempts == 1, let last = lastAttemptAt, now.timeIntervalSince(last) >= retryDelay {
            attempts = 2
            lastAttemptAt = now
            armed = false
            return true
        }
        return false
    }
}

/// Public CoreAudio process objects (macOS 14.2+): is Safari/WebKit producing audio?
enum WebKitAudioProbe {
    static func isPlaying() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return false }

        for id in ids {
            guard runningOutput(id), let bundle = bundleID(id) else { continue }
            if bundle.hasPrefix("com.apple.Safari") || bundle.hasPrefix("com.apple.WebKit") { return true }
        }
        return false
    }

    private static func runningOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Synthesizes the keyboard Play/Pause media key (NX_KEYTYPE_PLAY, IOKit
/// hidsystem/ev_keymap.h) with public NSEvent/CGEvent API. Requires the user to
/// allow this app under Privacy & Security ▸ Accessibility (CGPreflightPostEventAccess).
@MainActor
enum MediaKey {
    private static let playKeyCode = 16 // NX_KEYTYPE_PLAY

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestPostEventAccess() }

    static func safariIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
    }

    @discardableResult
    static func sendPlay() -> Bool {
        guard hasPermission else { return false }
        for state in [0xA, 0xB] {
            let data1 = (playKeyCode << 16) | (state << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1
            ) else { return false }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }
}
