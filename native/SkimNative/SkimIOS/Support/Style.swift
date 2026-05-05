import SwiftUI

enum SkimStyle {
    static let background = Color(red: 0.034, green: 0.049, blue: 0.066)
    static let chrome = Color(red: 0.071, green: 0.090, blue: 0.114)
    static let surface = Color(red: 0.087, green: 0.108, blue: 0.135)
    static let separator = Color(red: 0.145, green: 0.166, blue: 0.196)
    static let text = Color(red: 0.90, green: 0.93, blue: 0.96)
    static let secondary = Color(red: 0.48, green: 0.52, blue: 0.59)
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
    var size: CGFloat = 28
    var tapSize: CGFloat = 54
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .frame(width: tapSize, height: tapSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? SkimStyle.accent : SkimStyle.secondary)
        .accessibilityLabel(title)
    }
}

struct SkimWordmark: View {
    var size: CGFloat = 48

    private var font: Font {
        .custom("AquireBold", size: size)
    }

    private var fill: LinearGradient {
        LinearGradient(
            colors: [
                Color.white,
                Color(red: 0.91, green: 0.95, blue: 0.99),
                Color(red: 0.67, green: 0.74, blue: 0.81)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack {
            wordmark
                .foregroundStyle(Color.black.opacity(0.68))
                .offset(x: 0, y: 3.2)
                .blur(radius: 0.45)

            wordmark
                .foregroundStyle(Color(red: 0.43, green: 0.49, blue: 0.56))
                .offset(x: 0, y: 1.6)

            wordmark
                .foregroundStyle(fill)
                .offset(x: -0.35, y: 0)
            wordmark
                .foregroundStyle(fill)
                .offset(x: 0.35, y: 0)
            wordmark
                .foregroundStyle(fill)
        }
        .shadow(color: SkimStyle.accent.opacity(0.07), radius: 3.5, x: 0, y: 0)
        .fixedSize()
        .accessibilityLabel("Skim")
    }

    private var wordmark: some View {
        Text("SKIM")
            .font(font)
            .tracking(size * 0.12)
    }
}
