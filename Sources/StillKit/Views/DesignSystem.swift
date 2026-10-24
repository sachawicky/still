import SwiftUI

/// Shared visual vocabulary. Surfaces belong to controls and attention, not every row.
enum StillDesign {
    static let width: CGFloat = 344
    static let inset: CGFloat = 22
    static let radius: CGFloat = 18
    static let accent = Color(red: 0.36, green: 0.49, blue: 0.84)
    static let ambientText = Color(white: 0.94)
    static let ink = Color(red: 0.10, green: 0.13, blue: 0.23)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let caption = Font.caption
    static let body = Font.body
}

struct StillSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuietIconButton: View {
    let title: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30).contentShape(Circle())
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .help(title).accessibilityLabel(title)
    }
}

struct StillGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat = StillDesign.radius
    func body(content: Content) -> some View {
        if opaque || contrast == .increased {
            content.background(.background, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

struct InlineNotice: View {
    let text: String
    var symbol = "exclamationmark.triangle"
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(.orange)
        }
        .font(StillDesign.caption).foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

struct StillToggle: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
