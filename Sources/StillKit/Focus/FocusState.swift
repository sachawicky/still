import Foundation
import CryptoKit

public enum FocusProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex
    public var name: String { self == .claude ? "Claude Code" : "Codex" }
}

public enum FocusEventKind: String, Codable, Sendable {
    case permission, question, started, ended, guiBegin, guiEnd
    public var needsAttention: Bool { self == .permission || self == .question }
    public var context: String {
        self == .permission ? "Review the permission request in your agent." : "Your agent has a question. Open it to respond."
    }
}

/// Sanitized on ingress. Never stores commands, answers, transcripts, or full paths.
public struct FocusEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var provider: FocusProvider
    public var session: String
    public var kind: FocusEventKind
    public var project: String
    public var target: String?
    public var date: Date

    public init(id: String = UUID().uuidString, key: String, provider: FocusProvider, session: String,
                kind: FocusEventKind, project: String = "Project", target: String? = nil, date: Date = Date()) {
        self.id = id; self.key = key; self.provider = provider; self.session = session
        self.kind = kind; self.project = project; self.target = target; self.date = date
    }
}

public protocol FocusEventProvider {
    func event(from data: Data, now: Date, terminal: String?, userApprovals: Bool) -> FocusEvent?
}

/// Only the documented hook envelope is accepted. Transcript formats are not an API.
public struct HookEventProvider: FocusEventProvider {
    public let provider: FocusProvider
    public init(_ provider: FocusProvider) { self.provider = provider }
    public func event(from data: Data, now: Date = Date(), terminal: String? = nil, userApprovals: Bool = false) -> FocusEvent? {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hook = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String, !session.isEmpty else { return nil }
        let kind: FocusEventKind
        switch (provider, hook) {
        case (_, "SessionStart"): kind = .started
        case (_, "SessionEnd"): kind = .ended
        case (.claude, "Notification"):
            switch object["notification_type"] as? String {
            case "permission_prompt": kind = .permission
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": kind = .question
            default: return nil
            }
        case (.codex, "PreToolUse"):
            // Exact local tool name, not a transcript or a guess based on text.
            guard object["tool_name"] as? String == "request_user_input",
                  let input = object["tool_input"] as? [String: Any],
                  let questions = input["questions"] as? [[String: Any]], !questions.isEmpty,
                  questions.allSatisfy({ ($0["question"] as? String)?.isEmpty == false }) else { return nil }
            kind = .question
        case (.codex, "PermissionRequest") where userApprovals: kind = .permission
        default: return nil
        }
        let cwd = object["cwd"] as? String ?? ""
        let project = String(URL(fileURLWithPath: cwd).lastPathComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.map(String.init).joined().prefix(80))
        let input = (try? JSONSerialization.data(withJSONObject: object["tool_input"] ?? [:], options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        let discriminator = (object["tool_use_id"] as? String ?? object["turn_id"] as? String ?? "")
            + (object["notification_type"] as? String ?? "") + (object["message"] as? String ?? "")
            + (object["tool_name"] as? String ?? "") + digest(input)
        let sessionHash = digest(Data(session.utf8))
        return FocusEvent(key: digest(Data("\(provider.rawValue):\(sessionHash):\(kind.rawValue):\(discriminator)".utf8)),
                          provider: provider, session: sessionHash, kind: kind,
                          project: project.isEmpty ? "Project" : project,
                          target: Self.targetBundle(terminal), date: now)
    }
    public static func targetBundle(_ terminal: String?) -> String? {
        switch terminal {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "com.mitchellh.ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public struct FocusAttentionState: Sendable {
    public private(set) var pending: [FocusEvent] = []
    public init() {}
    @discardableResult public mutating func insert(_ event: FocusEvent) -> Bool {
        guard event.kind.needsAttention, !pending.contains(where: { $0.key == event.key }) else { return false }
        pending.append(event)
        pending.sort { $0.date < $1.date }
        return true
    }
    public mutating func dismiss(_ id: String) { pending.removeAll { $0.id == id } }
}

public struct FocusSettings: Codable, Equatable, Sendable {
    /// nil uses external displays automatically; [] intentionally selects no displays.
    public var displays: [String]? = nil
    public var theme: AmbientTheme = .midnight
    public var clock = true
    public var motion = true
    public var sound = "Glass"
    public var volume: Double = 0.5
    public var nativeNotifications = false
    public var autoActivate = false
    public var guiAutomation = false
    public init() {}
    enum CodingKeys: String, CodingKey {
        case displays, theme, clock, motion, sound, volume, nativeNotifications, autoActivate, guiAutomation
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displays = try c.decodeIfPresent([String].self, forKey: .displays)
        theme = (try? c.decode(AmbientTheme.self, forKey: .theme)) ?? .midnight
        clock = try c.decodeIfPresent(Bool.self, forKey: .clock) ?? true
        motion = try c.decodeIfPresent(Bool.self, forKey: .motion) ?? true
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? "Glass"
        volume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5))
        nativeNotifications = try c.decodeIfPresent(Bool.self, forKey: .nativeNotifications) ?? false
        autoActivate = try c.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? false
        guiAutomation = try c.decodeIfPresent(Bool.self, forKey: .guiAutomation) ?? false
    }
    public static let key = "stillFocusSettings.v1"
    /// Explicit opt-in used by the local setup command. Preserve even settings
    /// written by a newer app version; malformed preferences are never replaced.
    public static func enableNativeNotifications(in defaults: UserDefaults) throws {
        var object: [String: Any] = [:]
        if let data = defaults.data(forKey: key) {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            object = value
        }
        object["nativeNotifications"] = true
        defaults.set(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), forKey: key)
    }
    public static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

public struct FocusDisplay: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public init(id: String, name: String, builtIn: Bool) { self.id = id; self.name = name; self.builtIn = builtIn }
}

public enum FocusDisplayPolicy {
    public static func selected(_ displays: [FocusDisplay], preference: [String]?) -> Set<String> {
        if let preference { return Set(displays.map(\.id)).intersection(preference) }
        let external = displays.filter { !$0.builtIn }
        return Set((external.isEmpty ? Array(displays.prefix(1)) : external).map(\.id))
    }
}
