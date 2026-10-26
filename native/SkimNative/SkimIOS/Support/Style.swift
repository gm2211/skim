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

/// One SF Symbol per action or destination, shared by every iOS surface so the
/// same thing never shows two icons. Mostly mirrors the desktop icon set
/// (src/components/ui/icons.tsx): Today is the newspaper, "Catch me up" (on
/// Today) the bolt, AI Inbox the tray. Unread, All and Search use the icons
/// Giulio picked for the iOS bottom bar (2026-10-13).
enum SkimIcon {
    // Destinations
    static let today = "newspaper"
    static let aiInbox = "tray"
    static let allArticles = "text.justify.left"
    static let unread = "tray.full"
    static let starred = "star"
    static let recent = "clock"
    static let search = "magnifyingglass.circle"
    static let settings = "gearshape"
    static let feeds = "line.3.horizontal"

    // Actions
    static let chat = "bubble.left"
    static let summarize = "sparkles"
    static let addFeed = "plus"
    static let refresh = "arrow.clockwise"
    static let more = "ellipsis"
    static let back = "chevron.left"
    static let reader = "book"
    static let web = "globe"
    static let openExternal = "arrow.up.right.square"
    static let share = "square.and.arrow.up"
    static let copy = "doc.on.doc"
    static let star = "star"
    static let starFilled = "star.fill"
    static let unstar = "star.slash"
    static let markRead = "checkmark.circle"
    static let markUnread = "circle"
    static let pin = "pin"
    static let unpin = "pin.slash"
    static let rate = "list.number"
    static let discussion = "bubble.left.and.bubble.right"
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

/// An on/off switch for Smart sorting: a sparkles capsule, filled with the
/// accent when the list is ranked For you, outlined when it is newest first.
struct SmartSortToggle: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : SkimStyle.secondary)
                .frame(width: 44, height: 28)
                .background(Capsule().fill(isOn ? SkimStyle.accent : Color.clear))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : SkimStyle.secondary.opacity(0.45), lineWidth: 1))
                .frame(height: 42)
                .contentShape(Rectangle())
                .animation(.smooth(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Smart sorting")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint("Ranks unread articles for you when on; newest first when off")
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
