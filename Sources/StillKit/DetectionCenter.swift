import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

public struct StreamTarget: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case audio = "AirPlay audio"
        case mirroring = "Display mirroring"
    }

    public var kind: Kind
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

public struct DetectionSnapshot: Sendable, Equatable {
    public var targets: [StreamTarget]
    public var batteryPercent: Int
    public var onBattery: Bool
    public var thermalNominalOrFair: Bool
    public var lowPowerMode: Bool
    public var lidClosed: Bool
    public var agent: CodingAgent?

    public var streamActive: Bool { !targets.isEmpty }
    public var agentActive: Bool { agent != nil }

    public init(
        targets: [StreamTarget] = [],
        batteryPercent: Int = -1,
        onBattery: Bool = false,
        thermalNominalOrFair: Bool = true,
        lowPowerMode: Bool = false,
        lidClosed: Bool = false,
        agent: CodingAgent? = nil
    ) {
        self.targets = targets
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.thermalNominalOrFair = thermalNominalOrFair
        self.lowPowerMode = lowPowerMode
        self.lidClosed = lidClosed
        self.agent = agent
    }
}

private final class CallbackBox {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}

@MainActor
public final class DetectionCenter {
    public var onChange: (() -> Void)?

    private var powerSourceBox: CallbackBox?
    private var powerSource: CFRunLoopSource?
    private var displayBox: CallbackBox?
    private var displayRegistered = false
    private var audioBlocks: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private let agents = AgentWatcher()

    public init() {
        agents.onChange = { [weak self] in self?.notify() }
        setUpPowerSourceNotifications()
        setUpDisplayNotifications()
        setUpAudioNotifications()
        setUpSystemNotifications()
        setUpPollTimer()
    }

    public func snapshot() -> DetectionSnapshot {
        DetectionSnapshot(
            targets: streamTargets(),
            batteryPercent: batteryPercent(),
            onBattery: onBattery(),
            thermalNominalOrFair: ProcessInfo.processInfo.thermalState == .nominal
                || ProcessInfo.processInfo.thermalState == .fair,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            lidClosed: lidClosed() ?? false,
            agent: agents.workingAgent()
        )
    }

    /// Cheap enough to sample every couple of seconds while a stream is held.
    public func lidIsClosed() -> Bool { lidClosed() ?? false }
    public func browserPlaybackActive() -> Bool { WebKitAudioProbe.isPlaying() }

    public func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    // MARK: - Stream detection

    private func streamTargets() -> [StreamTarget] {
        var targets: [StreamTarget] = []
        if let output = defaultOutput(), output.transport == kAudioDeviceTransportTypeAirPlay {
            targets.append(StreamTarget(kind: .audio, name: output.name))
        }
        targets.append(contentsOf: mirroringTargets())
        return targets
    }

    private func defaultOutput() -> (id: AudioDeviceID, name: String, transport: UInt32)? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        let deviceName = (name?.takeRetainedValue() as String?) ?? "Audio output"

        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport)

        return (deviceID, deviceName, transport)
    }

    private func mirroringTargets() -> [StreamTarget] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success, count >= 2 else { return [] }

        let online = Array(ids.prefix(Int(count)))
        var targets: [StreamTarget] = []
        var seen: Set<CGDirectDisplayID> = []

        for id in online {
            let master = CGDisplayMirrorsDisplay(id)
            guard master != 0, master != id, !seen.contains(master) else { continue }
            seen.insert(master)
            seen.insert(id)
            let name = screenName(for: master) ?? screenName(for: id) ?? "Connected display"
            targets.append(StreamTarget(kind: .mirroring, name: name))
        }
        if targets.isEmpty {
            for id in online where CGDisplayIsInMirrorSet(id) != 0 {
                let name = screenName(for: id) ?? "Connected display"
                targets.append(StreamTarget(kind: .mirroring, name: name))
                break
            }
        }
        return targets
    }

    private func screenName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value == displayID else { continue }
            return screen.localizedName
        }
        return nil
    }

    // MARK: - Power / battery / lid

    private func batteryPercent() -> Int {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return -1 }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
               let capacity = description[kIOPSMaxCapacityKey as String] as? Int,
               capacity > 0 {
                return min(100, max(0, current * 100 / capacity))
            }
        }
        return -1
    }

    private func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (sourceType as String) == (kIOPSBatteryPowerValue as String)
    }

    private func lidClosed() -> Bool? {
        RootDomain.boolProperty("AppleClamshellState")
    }

    // MARK: - Event wiring

    private func setUpPowerSourceNotifications() {
        let box = CallbackBox { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        powerSourceBox = box
        guard let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
                box.handler()
            },
            Unmanaged.passUnretained(box).toOpaque()
        )?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    private func setUpDisplayNotifications() {
        let box = CallbackBox { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        displayBox = box
        let status = CGDisplayRegisterReconfigurationCallback(
            { _, _, context in
                guard let context else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
                box.handler()
            },
            Unmanaged.passUnretained(box).toOpaque()
        )
        displayRegistered = status == .success
    }

    private func setUpAudioNotifications() {
        guard let output = defaultOutput() else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.onChange?() }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(output.id, &address) {
            if AudioObjectAddPropertyListenerBlock(output.id, &address, DispatchQueue.main, block) == noErr {
                audioBlocks.append((output.id, block))
            }
        }
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            block
        ) == noErr {
            audioBlocks.append((AudioObjectID(kAudioObjectSystemObject), block))
        }
    }

    private func setUpSystemNotifications() {
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            NSWorkspace.didWakeNotification
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.notify()
                    }
                }
            )
        }
    }

    private func setUpPollTimer() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.agents.refreshRoots()
                self?.notify()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
