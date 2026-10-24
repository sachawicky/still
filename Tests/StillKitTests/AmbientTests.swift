import XCTest
@testable import StillKit

final class AmbientTests: XCTestCase {
    func testRenderingStopsForHiddenReducedMotionAndThermalPressure() {
        func rate(visible: Bool = true, motion: Bool = true, reduced: Bool = false,
                  lowPower: Bool = false, battery: Bool = false, thermal: Int = 0) -> Double {
            AmbientPolicy.frameRate(visible: visible, motion: motion, reduceMotion: reduced,
                                    lowPower: lowPower, onBattery: battery, thermal: thermal)
        }
        XCTAssertEqual(rate(), 60)
        XCTAssertEqual(rate(battery: true), 12)
        XCTAssertEqual(rate(lowPower: true), 12)
        XCTAssertEqual(rate(thermal: 1), 12)
        XCTAssertEqual(rate(visible: false), 0)
        XCTAssertEqual(rate(motion: false), 0)
        XCTAssertEqual(rate(reduced: true), 0)
        XCTAssertEqual(rate(thermal: 2), 0)
        XCTAssertEqual(rate(thermal: 3), 0)
    }
    func testContinuousPhasesEvolveVisiblyAndStayPreciseForLongSessions() {
        let initial = AmbientPolicy.phases(at: 0)
        let afterThreeSeconds = AmbientPolicy.phases(at: 3)
        XCTAssertGreaterThan(afterThreeSeconds.x - initial.x, 0.3)
        for time in [0.0, 54.636, 10_000, 604_800, 31_536_000] {
            let a = AmbientPolicy.phases(at: time)
            let b = AmbientPolicy.phases(at: time + 1.0 / 60)
            for i in 0..<4 {
                XCTAssertTrue(a[i].isFinite)
                XCTAssertLessThanOrEqual(abs(a[i]), Float.pi)
                // Trigonometric coordinates remain continuous even when a phase wraps.
                XCTAssertLessThan(abs(sin(a[i]) - sin(b[i])), 0.0021)
                XCTAssertLessThan(abs(cos(a[i]) - cos(b[i])), 0.0021)
            }
        }
    }
    func testRenderBudgetPreservesAspectAndCapsRetinaAndBatteryWork() {
        let retina = CGSize(width: 7680, height: 4320)
        XCTAssertEqual(AmbientPolicy.drawableSize(retina, constrained: false), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(AmbientPolicy.drawableSize(retina, constrained: true), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(AmbientPolicy.drawableSize(retina, constrained: false, scale: 0.5), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(AmbientPolicy.drawableSize(.zero, constrained: false), CGSize(width: 1, height: 1))
        XCTAssertEqual(AmbientPolicy.drawableSize(CGSize(width: 600, height: 900), constrained: false), CGSize(width: 600, height: 900))
    }
    func testOriginalPaletteAnchorsAreUnchanged() {
        XCTAssertEqual(AmbientTheme.midnight.palette, [SIMD3(0.018, 0.025, 0.065), SIMD3(0.07, 0.16, 0.33), SIMD3(0.23, 0.16, 0.37)])
        XCTAssertEqual(AmbientTheme.aurora.palette, [SIMD3(0.015, 0.055, 0.085), SIMD3(0.08, 0.34, 0.34), SIMD3(0.24, 0.22, 0.44)])
        XCTAssertEqual(AmbientTheme.monochrome.palette, [SIMD3(repeating: 0.025), SIMD3(repeating: 0.17), SIMD3(repeating: 0.32)])
    }
    func testVersionOneSettingsPreservePreferencesWhenThemeIsAdded() throws {
        let data = Data(#"{"displays":[],"clock":false,"motion":false,"sound":"Pop","volume":0.2,"nativeNotifications":true,"autoActivate":true,"guiAutomation":true}"#.utf8)
        let settings = try JSONDecoder().decode(FocusSettings.self, from: data)
        XCTAssertEqual(settings.theme, .midnight)
        XCTAssertEqual(settings.displays, [])
        XCTAssertFalse(settings.clock)
        XCTAssertFalse(settings.motion)
        XCTAssertEqual(settings.sound, "Pop")
        XCTAssertEqual(settings.volume, 0.2)
        XCTAssertTrue(settings.nativeNotifications && settings.autoActivate && settings.guiAutomation)
        for theme in AmbientTheme.allCases {
            var changed = settings; changed.theme = theme
            XCTAssertEqual(try JSONDecoder().decode(FocusSettings.self, from: JSONEncoder().encode(changed)), changed)
        }
    }
    func testUnknownThemeFallsBackWithoutLosingOtherPreferences() throws {
        let settings = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"theme":"future","clock":false,"volume":7}"#.utf8))
        XCTAssertEqual(settings.theme, .midnight)
        XCTAssertFalse(settings.clock)
        XCTAssertEqual(settings.volume, 1)
    }
}
