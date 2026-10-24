import AppKit
import Combine
import SwiftUI

public enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var colorScheme: ColorScheme? {
        switch self { case .automatic: nil; case .light: .light; case .dark: .dark }
    }
    public static let key = "stillAppearance.v2"
    public static func load(_ defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: key) ?? "") ?? .automatic
    }
}

@MainActor
public final class AppearanceController: ObservableObject {
    @Published public var preference: AppearancePreference {
        didSet { defaults.set(preference.rawValue, forKey: AppearancePreference.key); apply() }
    }
    private let defaults: UserDefaults
    private var controlsApplication = false
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = .load(defaults)
    }
    public func useForApplication() { controlsApplication = true; apply() }
    private func apply() {
        guard controlsApplication else { return }
        switch preference {
        case .automatic: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
