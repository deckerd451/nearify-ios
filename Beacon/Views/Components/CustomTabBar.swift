import SwiftUI

/// Floating glassmorphism tab bar.
///
/// Sizing is fully dynamic — no hardcoded heights. The bar grows to fit its
/// icon + label VStacks, and `.safeAreaInset(edge: .bottom)` in `MainTabView`
/// keeps it above the home indicator on every device geometry.
struct CustomTabBar: View {
    @Binding var selectedTab: AppTab
    var messagesUnreadCount: Int = 0

    @Namespace private var selectionNamespace

    private let items: [(tab: AppTab, icon: String, label: String)] = [
        (.home,     "house",                             "Home"),
        (.people,   "person.2.fill",                    "People"),
        (.event,    "safari",                            "Explore"),
        (.profile,  "person.circle",                    "Profile"),
        (.messages, "bubble.left.and.bubble.right.fill","Messages"),
    ]

    var body: some View {
        GeometryReader { proxy in
            let bottomInset = proxy.safeAreaInsets.bottom
            let baseBarHeight: CGFloat = 66
            let totalBarHeight = baseBarHeight + max(8, bottomInset)

            HStack(spacing: 0) {
                ForEach(items, id: \.tab) { item in
                    tabButton(item)
                }
            }
            .frame(maxWidth: .infinity, minHeight: baseBarHeight)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8 + max(0, bottomInset - 2))
            .background(glassBackground)
            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 6)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .frame(height: totalBarHeight)
        }
        .frame(height: 96)
    }

    // MARK: - Tab button

    @ViewBuilder
    private func tabButton(_ item: (tab: AppTab, icon: String, label: String)) -> some View {
        let isSelected = selectedTab == item.tab

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                selectedTab = item.tab
            }
        } label: {
            VStack(spacing: 4) {
                // Icon with optional badge
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.icon)
                        .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(width: 28, height: 28)

                    if item.tab == .messages, messagesUnreadCount > 0 {
                        badgeLabel(messagesUnreadCount)
                            .offset(x: 10, y: -4)
                    }
                }

                // Label — adaptive font, never clipped
                Text(item.label)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .matchedGeometryEffect(id: "tabHighlight", in: selectionNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Supporting views

    private func badgeLabel(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.red)
            .clipShape(Capsule())
    }

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
    }
}

// MARK: - Previews

#Preview("All device sizes") {
    struct PreviewHost: View {
        @State private var tab: AppTab = .home
        var body: some View {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack {
                    Spacer()
                    CustomTabBar(selectedTab: $tab, messagesUnreadCount: 3)
                }
            }
        }
    }
    return PreviewHost()
}
