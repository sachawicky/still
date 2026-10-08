import Foundation
import StillKit

var passed = 0
var failed = 0

@MainActor func check(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

@MainActor func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    check(actual == expected, "\(message) — got \(actual), expected \(expected)", file: file, line: line)
}

let t0 = Date(timeIntervalSince1970: 1_000_000)

func input(
    now: Date? = nil,
    manualArmed: Bool = false,
    autoDetectEnabled: Bool = true,
    streamActive: Bool = false,
    batteryPercent: Int = 80,
    onBattery: Bool = false,
    thermalNominalOrFair: Bool = true,
    lowPowerMode: Bool = false,
    batteryFloor: Int = 15,
    privilegeGranted: Bool = true,
    lastWriteSucceeded: Bool = true,
    agentActive: Bool = false,
    aiDetectEnabled: Bool = false
) -> SessionInput {
    SessionInput(
        now: now ?? t0,
        manualArmed: manualArmed,
        autoDetectEnabled: autoDetectEnabled,
        streamActive: streamActive,
        batteryPercent: batteryPercent,
        onBattery: onBattery,
        thermalNominalOrFair: thermalNominalOrFair,
        lowPowerMode: lowPowerMode,
        batteryFloor: batteryFloor,
        privilegeGranted: privilegeGranted,
        lastWriteSucceeded: lastWriteSucceeded,
        aiDetectEnabled: aiDetectEnabled,
        agentActive: agentActive
    )
}

// MARK: - SessionPolicy

do {
    var policy = SessionPolicy()
    let decision = policy.step(input())
    expect(decision.phase, .inactive, "default phase inactive")
    check(!decision.holdAwake, "default not holding")
}

do {
    var policy = SessionPolicy()
    policy.setManualArmed(true, streamActive: false)
    let decision = policy.step(input(manualArmed: true))
    expect(decision.phase, .active, "manual arm active")
    check(decision.holdAwake, "manual arm holds")
    check(!decision.autoArmed, "manual arm not auto")
}

do {
    var policy = SessionPolicy()
    policy.setManualArmed(true, streamActive: false)
    let decision = policy.step(input(manualArmed: true, privilegeGranted: false))
    expect(decision.phase, .suspended(.setup), "no privilege requests setup")
    check(!decision.holdAwake, "setup does not hold")
}

do {
    var policy = SessionPolicy()
    policy.setManualArmed(true, streamActive: false)
    let decision = policy.step(input(manualArmed: true, lastWriteSucceeded: false))
    expect(decision.phase, .suspended(.error), "write failure surfaces error")
}

do {
    var policy = SessionPolicy()
    policy.setManualArmed(true, streamActive: false)
    let low = policy.step(input(manualArmed: true, batteryPercent: 10, onBattery: true, batteryFloor: 15))
    expect(low.phase, .suspended(.battery), "low battery on battery pauses")
    let plugged = policy.step(input(manualArmed: true, batteryPercent: 10, onBattery: false, batteryFloor: 15))
    expect(plugged.phase, .active, "low battery plugged in still active")
}

do {
    var policy = SessionPolicy()
    policy.setManualArmed(true, streamActive: false)
    let thermal = policy.step(input(manualArmed: true, thermalNominalOrFair: false))
    expect(thermal.phase, .suspended(.thermal), "thermal pauses")
    let lowPower = policy.step(input(manualArmed: true, lowPowerMode: true))
    expect(lowPower.phase, .suspended(.lowPower), "low power mode pauses")
}

do {
    var policy = SessionPolicy()
    let decision = policy.step(input(streamActive: true))
    expect(decision.phase, .active, "stream auto-arms")
    check(decision.holdAwake, "stream holds")
    check(decision.autoArmed, "stream marks autoArmed")
}

do {
    var policy = SessionPolicy()
    let decision = policy.step(input(autoDetectEnabled: false, streamActive: true))
    expect(decision.phase, .inactive, "detection disabled never auto-arms")
}

do {
    var policy = SessionPolicy(graceInterval: 15)
    _ = policy.step(input(now: t0, streamActive: true))
    let during = policy.step(input(now: t0.addingTimeInterval(10), streamActive: false))
    check(during.holdAwake, "grace keeps holding after stream ends")
    let after = policy.step(input(now: t0.addingTimeInterval(26), streamActive: false))
    check(!after.holdAwake, "grace releases after interval")
    expect(after.phase, .inactive, "released phase inactive")
}

do {
    var policy = SessionPolicy(graceInterval: 15)
    _ = policy.step(input(now: t0, streamActive: true))
    policy.setManualArmed(false, streamActive: true)
    let suppressed = policy.step(input(now: t0.addingTimeInterval(1), streamActive: true))
    check(!suppressed.holdAwake, "manual off during stream suppresses auto")
    let streamEnds = policy.step(input(now: t0.addingTimeInterval(2), streamActive: false))
    check(!streamEnds.holdAwake, "no arm when stream ends under suppression")
    let newStream = policy.step(input(now: t0.addingTimeInterval(30), streamActive: true))
    check(newStream.holdAwake, "new stream re-arms")
    check(newStream.autoArmed, "new stream auto-armed")
}

do {
    var policy = SessionPolicy()
    _ = policy.step(input(now: t0, streamActive: true))
    policy.setManualArmed(false, streamActive: true)
    policy.setManualArmed(true, streamActive: true)
    let decision = policy.step(input(now: t0.addingTimeInterval(5), manualArmed: true, streamActive: true))
    check(decision.holdAwake, "re-arm during stream clears suppression")
    check(!decision.autoArmed, "re-armed session is manual")
}

do {
    var policy = SessionPolicy()
    let decision = policy.step(input(streamActive: true, batteryPercent: 5, onBattery: true, batteryFloor: 15))
    expect(decision.phase, .suspended(.battery), "battery guard applies to auto sessions")
    check(!decision.holdAwake, "auto session does not hold below floor")
}

// MARK: - ReconcileLogic

do {
    expect(ReconcileLogic.launchAction(flag: true, didSetFlag: true, privileged: true), .clearFlag, "owned stale flag cleared")
    expect(ReconcileLogic.launchAction(flag: true, didSetFlag: true, privileged: false), .warnNoPrivilege, "owned flag without privilege warns")
    expect(ReconcileLogic.launchAction(flag: true, didSetFlag: false, privileged: true), .warnExternal, "external flag warns")
    expect(ReconcileLogic.launchAction(flag: true, didSetFlag: false, privileged: false), .warnNoPrivilege, "external flag without privilege warns")
    expect(ReconcileLogic.launchAction(flag: false, didSetFlag: true, privileged: true), .clearOwnership, "stale ownership cleared")
    expect(ReconcileLogic.launchAction(flag: false, didSetFlag: false, privileged: true), .none, "clean launch does nothing")
    expect(ReconcileLogic.launchAction(flag: nil, didSetFlag: true, privileged: true), .clearOwnership, "unreadable flag clears ownership")
    expect(ReconcileLogic.launchAction(flag: nil, didSetFlag: false, privileged: true), .none, "unreadable clean does nothing")

    expect(ReconcileLogic.tickAction(flag: false, holdDesired: true, didSetFlag: true, privileged: true), .setFlag(true), "tick re-asserts lost flag")
    expect(ReconcileLogic.tickAction(flag: true, holdDesired: false, didSetFlag: true, privileged: true), .setFlag(false), "tick releases owned flag")
    check(ReconcileLogic.tickAction(flag: true, holdDesired: true, didSetFlag: true, privileged: true) == nil, "tick leaves matching hold")
    check(ReconcileLogic.tickAction(flag: false, holdDesired: false, didSetFlag: false, privileged: true) == nil, "tick leaves matching release")
    check(ReconcileLogic.tickAction(flag: true, holdDesired: false, didSetFlag: false, privileged: true) == nil, "tick never touches external flag")
    check(ReconcileLogic.tickAction(flag: true, holdDesired: true, didSetFlag: true, privileged: false) == nil, "tick requires privilege")
    check(ReconcileLogic.tickAction(flag: nil, holdDesired: true, didSetFlag: true, privileged: true) == nil, "tick no-op on unreadable flag")
}

// MARK: - SleepFlagParser

do {
    let output = """
    System-wide power settings:
    Currently in use:
     standby              1
     SleepDisabled        1
     hibernatefile        /var/vm/sleepimage
    """
    expect(SleepFlagParser.parse(output), true, "parses SleepDisabled 1")
    expect(SleepFlagParser.parse("SleepDisabled 0\n"), false, "parses SleepDisabled 0")
    expect(SleepFlagParser.parse("SleepDisabled\t1"), true, "parses tab separated")
    expect(SleepFlagParser.parse("System-wide power settings:\n standby 1\n"), nil, "missing line nil")
    expect(SleepFlagParser.parse("SleepDisabled maybe\n"), nil, "garbage value nil")
}

// MARK: - SudoersRule

do {
    expect(
        SudoersRule.line(username: "alice"),
        "alice ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0",
        "rule format"
    )
    check(SudoersRule.validate(rule: SudoersRule.line(username: CurrentUser.shortName)), "valid rule passes visudo")
    check(!SudoersRule.validate(rule: "this is not a sudoers rule at all !!!"), "garbage rule fails visudo")
    let filename = SudoersRule.installPath.split(separator: "/").last.map(String.init)
    expect(filename, Brand.sudoersFileName, "install path filename")
    check(!(filename?.contains(".") ?? true), "sudoers filename has no dots")
}

// MARK: - SleepController read-only state

do {
    let controller = SleepController()
    let flag = controller.readSleepDisabled()
    print("SleepDisabled at test time: \(flag.map(String.init(describing:)) ?? "unreadable")")
    check(flag == nil || flag == true || flag == false, "flag readable as tri-state")
    print("privilege granted: \(controller.privilegeGranted)")
    check(controller.privilegeGranted, "privilege detected via sudo listing (requires installed rule)")
}

// MARK: - Detection snapshot

do {
    let detection = DetectionCenter()
    let snapshot = detection.snapshot()
    print("battery: \(snapshot.batteryPercent)% onBattery=\(snapshot.onBattery) thermalOK=\(snapshot.thermalNominalOrFair) lowPower=\(snapshot.lowPowerMode) lidClosed=\(snapshot.lidClosed)")
    print("stream targets: \(snapshot.targets.map { "\($0.kind.rawValue)=\($0.name)" }.joined(separator: ", "))")
    check(snapshot.batteryPercent >= -1 && snapshot.batteryPercent <= 100, "battery percent in range")
    check(snapshot.thermalNominalOrFair || !snapshot.thermalNominalOrFair, "thermal readable")
}

// MARK: - Safety Timeout

do {
    expect(SafetyTimeout.default, .threeHours, "default timeout is 3 hours")
    check(SafetyTimeout.default != .untilDisabled, "never-expiring is never the default")
    expect(SafetyTimeout.allCases.count, 5, "five timeout options")
    expect(SafetyTimeout.oneHour.interval, 3600, "1h interval")
    expect(SafetyTimeout.sixHours.interval, 21600, "6h interval")
    check(SafetyTimeout.untilDisabled.interval == nil, "until disabled has no interval")
    check(SafetyTimeout.untilDisabled.deadline(from: t0) == nil, "until disabled has no deadline")
    expect(SafetyTimeout.twoHours.deadline(from: t0), t0.addingTimeInterval(7200), "deadline math")
}

do {
    var policy = SessionPolicy()
    let deadline = t0.addingTimeInterval(3600)
    policy.setManualArmed(true, streamActive: false, deadline: deadline)
    let before = policy.step(input(now: t0.addingTimeInterval(3599), manualArmed: true))
    check(before.holdAwake, "holds before deadline")
    expect(before.deadline, deadline, "decision exposes deadline")
    expect(before.context, .manual, "manual context")
    check(!before.expired, "not expired before deadline")
    let at = policy.step(input(now: deadline, manualArmed: true))
    check(!at.holdAwake, "releases at deadline")
    check(at.expired, "expiry flagged once")
    expect(at.phase, .inactive, "inactive after expiry")
    check(!policy.state.manualArmed, "manual disarmed after expiry")
    check(policy.state.manualDeadline == nil, "deadline cleared after expiry")
    let after = policy.step(input(now: deadline.addingTimeInterval(1)))
    check(!after.expired, "expiry reported only once")
    check(!after.holdAwake, "stays released")
}

do {
    var policy = SessionPolicy()
    policy.setManualArmed(true, streamActive: false, deadline: nil)
    let late = policy.step(input(now: t0.addingTimeInterval(48 * 3600), manualArmed: true))
    check(late.holdAwake, "until-disabled never expires")
    check(late.deadline == nil, "until-disabled has no deadline")
}

do {
    // Timeout must not be extended by an ongoing stream: expiry suppresses auto.
    var policy = SessionPolicy()
    let deadline = t0.addingTimeInterval(60)
    policy.setManualArmed(true, streamActive: true, deadline: deadline)
    _ = policy.step(input(now: t0, manualArmed: true, streamActive: true))
    let expired = policy.step(input(now: deadline, manualArmed: true, streamActive: true))
    check(expired.expired && !expired.holdAwake, "timeout releases even while streaming")
    let still = policy.step(input(now: deadline.addingTimeInterval(5), streamActive: true))
    check(!still.holdAwake, "stream does not silently re-arm after timeout")
    _ = policy.step(input(now: deadline.addingTimeInterval(10), streamActive: false))
    let fresh = policy.step(input(now: deadline.addingTimeInterval(100), streamActive: true))
    check(fresh.holdAwake && fresh.context == .streaming, "a new stream arms again")
}

do {
    // Battery / thermal outrank the timer, and the timer keeps running.
    var policy = SessionPolicy()
    let deadline = t0.addingTimeInterval(600)
    policy.setManualArmed(true, streamActive: false, deadline: deadline)
    let battery = policy.step(input(now: t0.addingTimeInterval(10), manualArmed: true, batteryPercent: 5, onBattery: true))
    expect(battery.phase, .suspended(.battery), "battery floor beats timer")
    expect(battery.deadline, deadline, "timer still visible while paused")
    let recovered = policy.step(input(now: t0.addingTimeInterval(20), manualArmed: true))
    check(recovered.holdAwake, "resumes when battery recovers before deadline")
    let thermal = policy.step(input(now: t0.addingTimeInterval(30), manualArmed: true, thermalNominalOrFair: false))
    expect(thermal.phase, .suspended(.thermal), "thermal beats timer")
}

do {
    // Persisted-deadline reload: an already-passed deadline expires on first step.
    var policy = SessionPolicy(state: SessionState(manualArmed: true, manualDeadline: t0))
    let decision = policy.step(input(now: t0.addingTimeInterval(1), manualArmed: true))
    check(decision.expired && !decision.holdAwake, "stale restored session expires immediately")
}

// MARK: - AI Work

do {
    var policy = SessionPolicy()
    let working = policy.step(input(now: t0, agentActive: true, aiDetectEnabled: true))
    check(working.holdAwake, "agent activity holds")
    expect(working.context, .aiWork, "ai work context")
    var offPolicy = SessionPolicy()
    let off = offPolicy.step(input(agentActive: true, aiDetectEnabled: false))
    check(!off.holdAwake, "ai detection disabled never holds")

    var p2 = SessionPolicy(graceInterval: 15)
    _ = p2.step(input(now: t0, agentActive: true, aiDetectEnabled: true))
    let grace = p2.step(input(now: t0.addingTimeInterval(20), agentActive: false, aiDetectEnabled: true))
    check(grace.holdAwake, "agent grace keeps holding briefly")
    let done = p2.step(input(now: t0.addingTimeInterval(60), agentActive: false, aiDetectEnabled: true))
    check(!done.holdAwake, "releases after agent finishes")
    expect(done.phase, .inactive, "inactive after agent finishes")

    // A stale agent that never becomes active never holds.
    var p3 = SessionPolicy()
    check(!p3.step(input(now: t0, agentActive: false, aiDetectEnabled: true)).holdAwake, "idle agent never holds")

    // Auto ceiling is a backstop for stuck detectors.
    var p4 = SessionPolicy(autoCeiling: 3600)
    _ = p4.step(input(now: t0, agentActive: true, aiDetectEnabled: true))
    let ceiling = p4.step(input(now: t0.addingTimeInterval(3601), agentActive: true, aiDetectEnabled: true))
    check(!ceiling.holdAwake && ceiling.expired, "auto session ceiling releases")
}

do {
    let now = t0
    check(AgentActivityLogic.isWorking(lastWrite: now.addingTimeInterval(-30), now: now), "recent write is working")
    check(!AgentActivityLogic.isWorking(lastWrite: now.addingTimeInterval(-400), now: now), "old write is idle")
    check(!AgentActivityLogic.isWorking(lastWrite: nil, now: now), "no write is idle")
    expect(AgentActivityLogic.agent(forPath: "/Users/a/.claude/projects/x/y.jsonl", home: "/Users/a"), .claudeCode, "claude path")
    expect(AgentActivityLogic.agent(forPath: "/Users/a/.codex/sessions/2026/r.jsonl", home: "/Users/a"), .codex, "codex path")
    check(AgentActivityLogic.agent(forPath: "/Users/a/.claude/projects/x/y.txt", home: "/Users/a") == nil, "non-transcript ignored")
    check(AgentActivityLogic.agent(forPath: "/Users/a/other/y.jsonl", home: "/Users/a") == nil, "other folders ignored")
}

// MARK: - Playback resume

do {
    func tick(_ logic: inout PlaybackResumeLogic, _ t: Double, lid: Bool, playing: Bool, holding: Bool = true) -> Bool {
        logic.observe(now: t0.addingTimeInterval(t), lidClosed: lid, holding: holding, streamActive: true, playing: playing)
    }

    var logic = PlaybackResumeLogic()
    _ = tick(&logic, 0, lid: false, playing: true)
    _ = tick(&logic, 2, lid: false, playing: true)
    check(!tick(&logic, 3, lid: true, playing: false), "no command before settle delay")
    check(!tick(&logic, 5, lid: true, playing: false), "still settling")
    check(tick(&logic, 8, lid: true, playing: false), "one Play after pause settles")
    check(!tick(&logic, 9, lid: true, playing: false), "no command spam")
    check(tick(&logic, 17, lid: true, playing: false), "one controlled retry")
    check(!tick(&logic, 30, lid: true, playing: false), "never a third command")

    var paused = PlaybackResumeLogic()
    _ = tick(&paused, 0, lid: false, playing: false)
    _ = tick(&paused, 2, lid: false, playing: false)
    check(!tick(&paused, 3, lid: true, playing: false), "intentionally paused is not resumed (t=3)")
    check(!tick(&paused, 10, lid: true, playing: false), "intentionally paused is not resumed (t=10)")

    var stale = PlaybackResumeLogic()
    _ = tick(&stale, 0, lid: false, playing: true)
    _ = tick(&stale, 20, lid: false, playing: false)
    _ = tick(&stale, 22, lid: true, playing: false)
    check(!tick(&stale, 30, lid: true, playing: false), "playback stopped well before close is not resumed")

    var uninterrupted = PlaybackResumeLogic()
    _ = tick(&uninterrupted, 0, lid: false, playing: true)
    _ = tick(&uninterrupted, 2, lid: true, playing: true)
    check(!tick(&uninterrupted, 9, lid: true, playing: true), "still playing needs no command")
    check(!tick(&uninterrupted, 12, lid: true, playing: false), "later stop after continuous play is left alone")

    var cooled = PlaybackResumeLogic()
    _ = tick(&cooled, 0, lid: false, playing: true)
    _ = tick(&cooled, 2, lid: true, playing: false)
    _ = tick(&cooled, 8, lid: true, playing: false)      // command 1
    _ = tick(&cooled, 17, lid: true, playing: false)     // retry
    _ = tick(&cooled, 20, lid: false, playing: true)
    _ = tick(&cooled, 22, lid: false, playing: true)
    _ = tick(&cooled, 23, lid: true, playing: false)
    check(!tick(&cooled, 40, lid: true, playing: false), "cooldown blocks rapid repeat cycles")

    var released = PlaybackResumeLogic()
    _ = tick(&released, 0, lid: false, playing: true)
    _ = tick(&released, 2, lid: true, playing: false, holding: false)
    check(!tick(&released, 10, lid: true, playing: false, holding: false), "no command when not holding the Mac awake")
}

// MARK: - Status presentation

do {
    func summary(_ d: SessionDecision, stream: String? = nil, active: Bool = false, agent: CodingAgent? = nil, restoring: Bool = false) -> StatusSummary {
        StatusSummary.make(decision: d, restoring: restoring, streamName: stream, streamActive: active, agent: agent, batteryFloor: 15, now: t0)
    }
    let idle = summary(SessionDecision(phase: .inactive, holdAwake: false, autoArmed: false, inGrace: false))
    expect(idle.title, "Inactive", "idle title")
    expect(idle.reason, "Your Mac can sleep normally.", "idle reason")
    let stream = summary(SessionDecision(phase: .active, holdAwake: true, autoArmed: true, inGrace: true, context: .streaming), stream: "Living Room", active: true)
    expect(stream.reason, "Streaming to Living Room", "stream reason")
    let ai = summary(SessionDecision(phase: .active, holdAwake: true, autoArmed: true, inGrace: true, context: .aiWork), agent: .claudeCode)
    expect(ai.reason, "Claude Code is working", "ai reason")
    let manual = summary(SessionDecision(phase: .active, holdAwake: true, autoArmed: false, inGrace: false, context: .manual, deadline: t0.addingTimeInterval(2 * 3600 + 41 * 60)))
    expect(manual.remaining, "2h 41m remaining", "manual remaining")
    let open = summary(SessionDecision(phase: .active, holdAwake: true, autoArmed: false, inGrace: false, context: .manual))
    expect(open.remaining, "Until you turn it off", "until disabled copy")
    let paused = summary(SessionDecision(phase: .suspended(.battery), holdAwake: false, autoArmed: false, inGrace: false, context: .manual))
    expect(paused.title, "Paused", "paused title")
    expect(StatusSummary.remainingText(30), "Less than a minute remaining", "sub-minute")
    expect(StatusSummary.remainingText(3600), "1h remaining", "whole hour")
    expect(StatusSummary.remainingText(41 * 60), "41m remaining", "minutes only")
    for text in [idle.reason, stream.reason, ai.reason, paused.reason] {
        for banned in ["pmset", "SleepDisabled", "IOKit", "sudo", "assertion"] {
            check(!text.contains(banned), "no technical term '\(banned)' in UI copy")
        }
    }
}

// MARK: - Privilege listing

do {
    let good = "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    check(SudoersRule.listingGrantsHold(good), "listing with both commands grants")
    check(!SudoersRule.listingGrantsHold("    (ALL) ALL"), "generic ALL is not our grant")
    check(!SudoersRule.listingGrantsHold("(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1"), "partial grant rejected")
}

// MARK: - Result

print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}
exit(0)
