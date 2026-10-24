import XCTest
@testable import StillKit

final class FocusTests: XCTestCase {
    func testNotificationOptInPreservesOtherAndFutureSettingsAndRejectsCorruption() throws {
        let name = "StillNotificationOptInTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original: [String: Any] = ["nativeNotifications": false, "sound": "Pop", "volume": 0.25,
            "displays": ["external"], "autoActivate": false, "theme": "aurora", "futureSetting": ["keep": true]]
        defaults.set(try JSONSerialization.data(withJSONObject: original), forKey: FocusSettings.key)
        defaults.set(23, forKey: "batteryFloor")
        try FocusSettings.enableNativeNotifications(in: defaults)
        var expected = original; expected["nativeNotifications"] = true
        let actual = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: FocusSettings.key))) as! NSDictionary
        XCTAssertEqual(actual, expected as NSDictionary)
        XCTAssertEqual(defaults.integer(forKey: "batteryFloor"), 23)
        let corrupt = Data("invalid preferences".utf8)
        defaults.set(corrupt, forKey: FocusSettings.key)
        XCTAssertThrowsError(try FocusSettings.enableNativeNotifications(in: defaults))
        XCTAssertEqual(defaults.data(forKey: FocusSettings.key), corrupt)
    }
    private func payload(_ event: String, _ extra: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["session_id": "test-session", "hook_event_name": event, "cwd": "/private/work/Example"]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testClaudeActionableNotificationsOnly() throws {
        let provider = HookEventProvider(.claude)
        for name in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            let event = provider.event(from: try payload("Notification", ["notification_type": name]))
            XCTAssertEqual(event?.kind.needsAttention, true, name)
        }
        for name in ["idle_prompt", "auth_success", "agent_completed", "elicitation_complete", "unknown"] {
            XCTAssertNil(provider.event(from: try payload("Notification", ["notification_type": name])), name)
        }
        XCTAssertNil(provider.event(from: try payload("Stop")))
        // PermissionRequest is before other hooks may approve; only the actual waiting notification is used.
        XCTAssertNil(provider.event(from: try payload("PermissionRequest")))
    }
    func testCodexApprovalRoutingIsExplicit() throws {
        let data = try payload("PermissionRequest", ["tool_name": "Bash", "turn_id": "turn1", "tool_input": ["command": "private command"]])
        let provider = HookEventProvider(.codex)
        XCTAssertNil(provider.event(from: data))
        let event = try XCTUnwrap(provider.event(from: data, userApprovals: true))
        XCTAssertEqual(event.kind, .permission)
        XCTAssertEqual(event.project, "Example")
        let serialized = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        for secret in ["private command", "/private/work", "test-session"] { XCTAssertFalse(serialized.contains(secret)) }
        XCTAssertNil(provider.event(from: try payload("Notification", ["notification_type": "idle_prompt"])))
        XCTAssertNil(provider.event(from: try payload("Stop")))
        XCTAssertNil(provider.event(from: Data("not json".utf8)))
        XCTAssertNil(provider.event(from: Data(repeating: 0, count: 1_048_577)))
    }
    func testDeduplicationAndMultipleRequests() throws {
        let provider = HookEventProvider(.claude)
        let data = try payload("Notification", ["notification_type": "permission_prompt", "message": "needs permission"])
        let first = try XCTUnwrap(provider.event(from: data))
        let repeated = try XCTUnwrap(provider.event(from: data))
        var state = FocusAttentionState()
        XCTAssertTrue(state.insert(first))
        XCTAssertFalse(state.insert(repeated))
        let other = try XCTUnwrap(provider.event(from: try payload("Notification", ["notification_type": "agent_needs_input"])))
        XCTAssertTrue(state.insert(other))
        XCTAssertEqual(state.pending.count, 2)
        state.dismiss(first.id)
        XCTAssertEqual(state.pending.map(\.id), [other.id])
        XCTAssertTrue(state.insert(repeated), "A fresh request after dismissal can alert again")
        let lifecycle = try XCTUnwrap(provider.event(from: try payload("SessionStart")))
        XCTAssertFalse(state.insert(lifecycle))
    }
    func testDisplayLifecycleAndSelection() {
        let internalDisplay = FocusDisplay(id: "internal", name: "Built-in", builtIn: true)
        let external = FocusDisplay(id: "benq", name: "BenQ PD2705U", builtIn: false)
        XCTAssertEqual(FocusDisplayPolicy.selected([internalDisplay, external], preference: nil), ["benq"])
        XCTAssertEqual(FocusDisplayPolicy.selected([internalDisplay], preference: nil), ["internal"])
        XCTAssertEqual(FocusDisplayPolicy.selected([internalDisplay], preference: ["benq"]), [])
        XCTAssertEqual(FocusDisplayPolicy.selected([internalDisplay, external], preference: ["benq"]), ["benq"])
        XCTAssertEqual(FocusDisplayPolicy.selected([internalDisplay, external], preference: []), [])
        XCTAssertEqual(FocusDisplayPolicy.selected([], preference: nil), [])
    }
    func testSettingsRoundTripAndDefaults() throws {
        let name = "StillFocusTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = FocusSettings.load(defaults)
        XCTAssertFalse(initial.autoActivate)
        XCTAssertFalse(initial.nativeNotifications)
        XCTAssertFalse(initial.guiAutomation)
        XCTAssertNil(initial.displays)
        var settings = initial
        settings.displays = ["benq"]; settings.clock = false; settings.motion = false
        settings.sound = "None"; settings.volume = 0.25; settings.autoActivate = true
        settings.guiAutomation = true; settings.nativeNotifications = true
        settings.save(defaults)
        XCTAssertEqual(FocusSettings.load(defaults), settings)
        defaults.set(Data("invalid".utf8), forKey: FocusSettings.key)
        XCTAssertEqual(FocusSettings.load(defaults), initial)
    }
    func testDurableInboxAndSymlinkRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = FocusEvent(key: "key", provider: .claude, session: "hash", kind: .permission)
        try FocusInbox.write(event, to: directory)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(FocusInbox.read(file), event)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let link = directory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(FocusInbox.read(link))
        try Data(repeating: 0, count: 8193).write(to: file)
        XCTAssertNil(FocusInbox.read(file))
    }
    func testCodexExplicitQuestionTool() throws {
        let provider = HookEventProvider(.codex)
        let event = provider.event(from: try payload("PreToolUse", ["tool_name": "request_user_input",
            "tool_input": ["questions": [["question": "Choose an option"]]]]))
        XCTAssertEqual(event?.kind, .question)
        XCTAssertNil(provider.event(from: try payload("PreToolUse", ["tool_name": "Bash",
            "tool_input": ["command": "request_user_input"]])))
        XCTAssertNil(provider.event(from: try payload("PreToolUse", ["tool_name": "request_user_input",
            "tool_input": ["questions": []]])))
    }
    func testTargetIsAllowlisted() {
        XCTAssertEqual(HookEventProvider.targetBundle("Apple_Terminal"), "com.apple.Terminal")
        XCTAssertNil(HookEventProvider.targetBundle("arbitrary.untrusted.app"))
    }
}
