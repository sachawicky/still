import XCTest
import IOKit.pwr_mgt
@testable import StillKit

final class PowerSafetyTests: XCTestCase {
    private func input(_ lifecycle: PowerLifecycle = PowerLifecycle(), external: Bool = false,
                       battery: Int = 80, thermal: Bool = true, lowPower: Bool = false,
                       now: Date = Date()) -> SessionInput {
        SessionInput(now: now, manualArmed: true, autoDetectEnabled: true, streamActive: true,
                     batteryPercent: battery, onBattery: true, thermalNominalOrFair: thermal,
                     lowPowerMode: lowPower, batteryFloor: 15, privilegeGranted: true,
                     lastWriteSucceeded: true, aiDetectEnabled: true, agentActive: true,
                     systemAllowsHold: lifecycle.allowsHold, externalDisplayConnected: external)
    }

    func testEverySafetyInterruptionOverridesManualAndAutomaticActivity() {
        for event in [PowerLifecycle.Event.lock, .sessionInactive, .sleepRequested, .willSleep, .didWake, .terminate] {
            var lifecycle = PowerLifecycle()
            var policy = SessionPolicy(state: SessionState(manualArmed: true))
            XCTAssertTrue(policy.step(input()).holdAwake)
            lifecycle.receive(event)
            for _ in 0..<5 {
                XCTAssertFalse(policy.step(input(lifecycle)).holdAwake, "\(event)")
            }
        }
    }

    func testUnlockAndWakeRequireNewUserAction() {
        var lifecycle = PowerLifecycle()
        lifecycle.receive(.lock)
        lifecycle.resumeByUser()
        XCTAssertFalse(lifecycle.allowsHold, "Cannot arm while locked")
        lifecycle.sessionBecameActive()
        XCTAssertFalse(lifecycle.allowsHold, "Unlock must not auto-resume")
        lifecycle.resumeByUser()
        XCTAssertTrue(lifecycle.allowsHold)
        lifecycle.receive(.willSleep)
        lifecycle.resumeByUser()
        XCTAssertFalse(lifecycle.allowsHold)
        lifecycle.receive(.didWake)
        XCTAssertFalse(lifecycle.allowsHold)
        lifecycle.resumeByUser()
        XCTAssertTrue(lifecycle.allowsHold)
        lifecycle.receive(.terminate)
        lifecycle.receive(.didWake)
        lifecycle.resumeByUser()
        XCTAssertFalse(lifecycle.allowsHold)
    }

    func testExternalDisplayAndBatteryThermalLowPowerAlwaysRelease() {
        var policy = SessionPolicy(state: SessionState(manualArmed: true))
        XCTAssertTrue(policy.step(input()).holdAwake)
        XCTAssertEqual(policy.step(input(external: true)).phase, .suspended(.externalDisplay))
        XCTAssertTrue(policy.step(input(external: false)).holdAwake)
        XCTAssertFalse(policy.step(input(battery: 14)).holdAwake)
        XCTAssertFalse(policy.step(input(battery: -1)).holdAwake)
        XCTAssertFalse(policy.step(input(thermal: false)).holdAwake)
        XCTAssertFalse(policy.step(input(lowPower: true)).holdAwake)
    }

    func testExternalDisconnectCannotOverrideSleepLatch() {
        var lifecycle = PowerLifecycle()
        var policy = SessionPolicy(state: SessionState(manualArmed: true))
        XCTAssertFalse(policy.step(input(external: true)).holdAwake)
        lifecycle.receive(.sleepRequested)
        XCTAssertFalse(policy.step(input(lifecycle, external: false)).holdAwake)
        lifecycle.receive(.didWake)
        XCTAssertFalse(policy.step(input(lifecycle, external: false)).holdAwake)
    }

    func testAutomaticSessionHasFiniteCeilingAndDoesNotRearmWhileActivityStaysOn() {
        let start = Date()
        var policy = SessionPolicy()
        XCTAssertTrue(policy.step(input(now: start)).holdAwake)
        XCTAssertFalse(policy.step(input(now: start.addingTimeInterval(3 * 3600))).holdAwake)
        XCTAssertFalse(policy.step(input(now: start.addingTimeInterval(4 * 3600))).holdAwake)
    }

    func testUnknownLegacyFlagRetainsRecoveryResponsibilityAndNeverReenables() {
        XCTAssertEqual(ReconcileLogic.launchAction(flag: nil, didSetFlag: true, privileged: true), .clearFlag)
        XCTAssertEqual(ReconcileLogic.launchAction(flag: nil, didSetFlag: true, privileged: false), .warnNoPrivilege)
        XCTAssertNil(ReconcileLogic.tickAction(flag: false, holdDesired: true, didSetFlag: true, privileged: true))
    }

    @MainActor func testAssertionAcquireReleaseAreIdempotentAndDeinitReleases() {
        var created = 0, released = 0
        var assertion: AssertionController? = AssertionController(create: { _, id in
            created += 1; id = 42; return kIOReturnSuccess
        }, release: { id in
            XCTAssertEqual(id, 42); released += 1; return kIOReturnSuccess
        })
        XCTAssertTrue(assertion!.setActive(true, reason: "test"))
        XCTAssertTrue(assertion!.setActive(true, reason: "test"))
        XCTAssertEqual(created, 1)
        XCTAssertTrue(assertion!.setActive(false, reason: ""))
        XCTAssertTrue(assertion!.setActive(false, reason: ""))
        XCTAssertEqual(released, 1)
        XCTAssertTrue(assertion!.setActive(true, reason: "test"))
        assertion = nil
        XCTAssertEqual(released, 2)
    }

    @MainActor func testAssertionFailuresDoNotInventOwnershipOrLoseReleaseHandle() {
        let failed = AssertionController(create: { _, _ in kIOReturnError })
        XCTAssertFalse(failed.setActive(true, reason: "test"))
        XCTAssertFalse(failed.isActive)
        var releases = 0
        let assertion = AssertionController(create: { _, id in id = 42; return kIOReturnSuccess }, release: { _ in
            releases += 1; return releases == 1 ? kIOReturnError : kIOReturnSuccess
        })
        XCTAssertTrue(assertion.setActive(true, reason: "test"))
        XCTAssertFalse(assertion.setActive(false, reason: ""))
        XCTAssertTrue(assertion.isActive, "Keep handle so a failed release can be retried")
        XCTAssertTrue(assertion.setActive(false, reason: ""))
        XCTAssertFalse(assertion.isActive)
    }

    @MainActor func testExpiredKernelLeaseCannotBeRenewedByEvaluation() {
        var now = Date(), created = 0
        let assertion = AssertionController(create: { _, id in created += 1; id = 42; return kIOReturnSuccess },
                                            release: { _ in kIOReturnNotFound }, now: { now })
        XCTAssertTrue(assertion.setActive(true, reason: "test"))
        now = now.addingTimeInterval(3 * 3600)
        XCTAssertFalse(assertion.setActive(true, reason: "test"))
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(created, 1)
    }
}
