import XCTest
import AppKit
@testable import StillKit

final class AppearanceTests: XCTestCase {
    @MainActor func testFreshInstallAndPersistenceRemainSeparateFromAmbientTheme() throws {
        let name = "app.still.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let appearance = AppearanceController(defaults: defaults)
        XCTAssertEqual(appearance.preference, .automatic)
        XCTAssertNil(appearance.preference.colorScheme)
        var focus = FocusSettings(); focus.theme = .aurora; focus.save(defaults)
        appearance.preference = .light
        XCTAssertEqual(AppearanceController(defaults: defaults).preference, .light)
        XCTAssertEqual(FocusSettings.load(defaults).theme, .aurora)
        appearance.preference = .dark
        XCTAssertEqual(AppearanceController(defaults: defaults).preference, .dark)
        defaults.set("future", forKey: AppearancePreference.key)
        XCTAssertEqual(AppearancePreference.load(defaults), .automatic)
    }
    func testFreshDefaultsAndUpgradePreserveImplicitAndExplicitOptIns() {
        let name = "app.still.tests.migration.\(UUID().uuidString)", defaults = UserDefaults(suiteName: "app.still.tests.migration")!
        defer { defaults.removePersistentDomain(forName: "app.still.tests.migration") }
        defaults.removePersistentDomain(forName: "app.still.tests.migration")
        PreferenceMigration.migrate(defaults)
        XCTAssertFalse(defaults.bool(forKey: "autoDetectEnabled"), name)
        XCTAssertFalse(defaults.bool(forKey: "aiDetectEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "resumePlaybackEnabled"))
        defaults.removePersistentDomain(forName: "app.still.tests.migration")
        defaults.set(false, forKey: "manualArmed")
        defaults.set(false, forKey: "aiDetectEnabled")
        PreferenceMigration.migrate(defaults)
        XCTAssertTrue(defaults.bool(forKey: "autoDetectEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "aiDetectEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "resumePlaybackEnabled"))
        defaults.set(false, forKey: "autoDetectEnabled")
        PreferenceMigration.migrate(defaults)
        XCTAssertFalse(defaults.bool(forKey: "autoDetectEnabled"))
    }
    func testBothPalettesAreFiniteDistinctAndMonochromeIsNeutral() {
        for theme in AmbientTheme.allCases {
            let day = theme.palette(light: true), night = theme.palette(light: false)
            XCTAssertNotEqual(day, night)
            for color in day + night {
                for value in [color.x, color.y, color.z] { XCTAssertTrue(value.isFinite && (0...1).contains(value)) }
                if theme == .monochrome { XCTAssertEqual(color.x, color.y); XCTAssertEqual(color.y, color.z) }
            }
            // Worst-case light background versus Focus's ink; night background vs white.
            XCTAssertGreaterThan(contrast(day[0], SIMD3(0.10,0.13,0.23)), 7)
            XCTAssertGreaterThan(contrast(night[0], SIMD3(repeating: 0.94)), 7)
        }
    }
    private func contrast(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
        func luminance(_ c: SIMD3<Float>) -> Double {
            let v = [c.x,c.y,c.z].map { value -> Double in
                let s = Double(value); return s <= 0.04045 ? s / 12.92 : pow((s+0.055)/1.055, 2.4)
            }
            return v[0]*0.2126 + v[1]*0.7152 + v[2]*0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
    @MainActor func testFocusControllerReleasesWithoutInboxOrWindowLeaks() {
        let name = "app.still.tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: "app.still.tests.cleanup")!
        defer { defaults.removePersistentDomain(forName: "app.still.tests.cleanup") }
        weak var released: FocusController?
        autoreleasepool {
            let focus = FocusController(defaults: defaults, monitorInbox: false)
            focus.settings.guiAutomation = true
            focus.start()
            XCTAssertFalse(focus.active)
            XCTAssertNotNil(focus.note)
            focus.stop()
            released = focus
        }
        XCTAssertNil(released, name)
    }
}
