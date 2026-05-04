import SwiftUI

enum SkimStyle {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.078)
    static let surface = Color(red: 0.075, green: 0.095, blue: 0.125)
    static let text = Color(red: 0.90, green: 0.93, blue: 0.97)
    static let secondary = Color(red: 0.47, green: 0.51, blue: 0.58)
    static let accent = Color(red: 0.39, green: 0.64, blue: 1.0)
}

extension View {
    func skimGlass(cornerRadius: CGFloat = 22) -> some View {
        self
            .glassEffect(.regular.tint(.white.opacity(0.04)).interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct BorderlessIconButton: View {
    var systemName: String
    var title: String
    var isActive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? SkimStyle.accent : SkimStyle.secondary)
        .accessibilityLabel(title)
    }
}
