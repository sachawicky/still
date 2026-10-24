import Foundation

public enum PreferenceMigration {
    /// 1.2 persisted manualArmed at every launch, including the false value.
    /// Materialize its implicit opt-ins before applying safer defaults to new installs.
    public static func migrate(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: "stillDefaults.v2") else { return }
        let upgrading = defaults.object(forKey: "manualArmed") != nil || defaults.data(forKey: FocusSettings.key) != nil
        for key in ["autoDetectEnabled", "aiDetectEnabled", "resumePlaybackEnabled"] {
            if defaults.object(forKey: key) == nil { defaults.set(upgrading, forKey: key) }
        }
        defaults.set(true, forKey: "stillDefaults.v2")
    }
}
