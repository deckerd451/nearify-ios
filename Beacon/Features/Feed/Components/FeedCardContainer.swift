import SwiftUI

// MARK: - Feed Card Modifier

/// Dark-themed card styling applied as a view modifier.
/// Using a modifier instead of a wrapper view avoids generic container
/// issues where button hit testing can fail inside @ViewBuilder content.
struct FeedCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

extension View {
    func feedCard() -> some View {
        modifier(FeedCardModifier())
    }
}

// MARK: - Feed Card Container (legacy, kept for compatibility)

/// Reusable dark-themed card container for feed cards.
struct FeedCardContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .feedCard()
    }
}

// MARK: - Feed Action Button

/// Tappable action button used in feed cards.
/// Uses .onTapGesture for reliable tap detection inside ScrollView + LazyVStack.
/// .contentShape ensures the full padded area is tappable.
struct FeedActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            print("[FeedAction] 🔘 Button tapped: \(title)")
            action()
        }
    }
}

// MARK: - Legacy free function (kept for any remaining callers)

func feedActionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
    FeedActionButton(title: title, icon: icon, color: color, action: action)
}
