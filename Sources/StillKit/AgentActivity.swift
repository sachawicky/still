import CoreServices
import Foundation

/// Which coding agent wrote to its session transcript most recently.
public enum CodingAgent: String, Sendable, CaseIterable {
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var relativeRoot: String {
        switch self {
        case .claudeCode: return ".claude/projects"
        case .codex: return ".codex/sessions"
        }
    }
}

public enum AgentActivityLogic {
    /// Agents append to their transcript continuously while working. A write
    /// inside this window means "working"; silence means idle or finished.
    public static let workingWindow: TimeInterval = 180

    public static func isWorking(lastWrite: Date?, now: Date, window: TimeInterval = workingWindow) -> Bool {
        guard let lastWrite else { return false }
        let age = now.timeIntervalSince(lastWrite)
        return age >= -5 && age < window
    }

    public static func agent(forPath path: String, home: String) -> CodingAgent? {
        guard path.hasSuffix(".jsonl") else { return nil }
        for agent in CodingAgent.allCases where path.hasPrefix(home + "/" + agent.relativeRoot + "/") {
            return agent
        }
        return nil
    }
}

private final class WatcherBox {
    let handler: ([String]) -> Void
    init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }
}

/// Event-driven: watches transcript folders with FSEvents, never scans or polls.
@MainActor
public final class AgentWatcher {
    public var onChange: (() -> Void)?

    private var lastWrite: [CodingAgent: Date] = [:]
    private var stream: FSEventStreamRef?
    private var box: WatcherBox?
    private var watchedRoots: [String] = []
    private let home = NSHomeDirectory()

    public init() {
        refreshRoots()
    }

    /// Name of the agent that is working right now, if any.
    public func workingAgent(now: Date = Date()) -> CodingAgent? {
        lastWrite
            .filter { AgentActivityLogic.isWorking(lastWrite: $0.value, now: now) }
            .max { $0.value < $1.value }?
            .key
    }

    /// Starts watching folders that did not exist yet (agent installed later).
    public func refreshRoots() {
        let existing = CodingAgent.allCases
            .map { home + "/" + $0.relativeRoot }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != watchedRoots else { return }
        stop()
        watchedRoots = existing
        guard !existing.isEmpty else { return }

        let box = WatcherBox { [weak self] paths in
            MainActor.assumeIsolated { self?.handle(paths) }
        }
        self.box = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            box.handler(array.prefix(count).compactMap { $0 as? String })
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handle(_ paths: [String]) {
        let now = Date()
        var touched = false
        for path in paths {
            if let agent = AgentActivityLogic.agent(forPath: path, home: home) {
                lastWrite[agent] = now
                touched = true
            }
        }
        if touched { onChange?() }
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
