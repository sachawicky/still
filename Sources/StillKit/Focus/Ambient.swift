import SwiftUI

public enum AmbientTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case midnight, aurora, monochrome
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
    // Original Still 1.2 anchors. Lighting never substitutes a new theme palette.
    var palette: [SIMD3<Float>] {
        switch self {
        case .midnight: [SIMD3(0.018, 0.025, 0.065), SIMD3(0.07, 0.16, 0.33), SIMD3(0.23, 0.16, 0.37)]
        case .aurora: [SIMD3(0.015, 0.055, 0.085), SIMD3(0.08, 0.34, 0.34), SIMD3(0.24, 0.22, 0.44)]
        case .monochrome: [SIMD3(repeating: 0.025), SIMD3(repeating: 0.17), SIMD3(repeating: 0.32)]
        }
    }
    func palette(light: Bool) -> [SIMD3<Float>] {
        guard light else { return palette }
        switch self {
        case .midnight: return [SIMD3(0.94, 0.95, 0.98), SIMD3(0.55, 0.67, 0.82), SIMD3(0.69, 0.63, 0.80)]
        case .aurora: return [SIMD3(0.93, 0.97, 0.96), SIMD3(0.46, 0.72, 0.70), SIMD3(0.69, 0.64, 0.84)]
        case .monochrome: return [SIMD3(repeating: 0.95), SIMD3(repeating: 0.65), SIMD3(repeating: 0.78)]
        }
    }
    var colors: [Color] { palette.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) } }
}

/// Pure scheduling/geometry logic, independent of display size and pixel density.
public enum AmbientPolicy {
    public static func frameRate(visible: Bool, motion: Bool, reduceMotion: Bool,
                                 lowPower: Bool, onBattery: Bool, thermal: Int) -> Double {
        guard visible, motion, !reduceMotion, thermal < 2 else { return 0 }
        return lowPower || onBattery || thermal == 1 ? 12 : 60
    }
    /// Bounded phase coordinates, evaluated in Double before conversion to GPU floats.
    /// There is no reset/loop seam, including after long sessions and sleep.
    static func phases(at seconds: Double) -> SIMD4<Float> {
        let rates = SIMD4<Double>(0.115, 0.079, 0.053, 0.037)
        return SIMD4((0..<4).map { Float((seconds * rates[$0]).remainder(dividingBy: 2 * .pi)) })
    }
    static func drawableSize(_ size: CGSize, constrained: Bool, scale: Double = 1) -> CGSize {
        guard size.width.isFinite, size.height.isFinite else { return CGSize(width: 1, height: 1) }
        let longest = max(size.width, size.height, 1)
        let factor = min(1, (constrained ? 1920.0 : 3840.0) / longest) * min(1, max(0.5, scale))
        return CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
    }
}

/// SwiftUI keeps the readable lockup and native glass; Metal owns only the artwork.
/// No SwiftUI timeline or per-frame view invalidations are needed.
struct AmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    let theme: AmbientTheme
    var framesPerSecond: Double = 0
    var body: some View {
        ZStack {
            // Also serves as a graceful, static fallback if Metal is unavailable.
            LinearGradient(colors: theme.palette(light: scheme == .light).map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            AmbientMetalView(theme: theme, light: scheme == .light, framesPerSecond: reduceMotion ? 0 : framesPerSecond)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black).ignoresSafeArea().accessibilityHidden(true)
    }
}
