import SwiftUI

/// Shared spacing and typography tokens for visual consistency across root tabs.
enum DesignTokens {
    // MARK: - Spacing

    /// Space between the navigation title and the first content section.
    static let titleToContent: CGFloat = 8

    /// Space between major content sections.
    static let sectionSpacing: CGFloat = 24

    /// Space between a section header and its first child element.
    static let sectionHeaderToContent: CGFloat = 16

    /// Space between related sub-elements within a section.
    static let elementSpacing: CGFloat = 12

    /// Bottom padding for scrollable content.
    static let scrollBottomPadding: CGFloat = 32

    /// Extra clearance reserved by scrollable root-tab content for the custom
    /// floating tab bar. Keep this centralized so root tabs do not each guess at
    /// the overlay height.
    static let tabBarContentClearance: CGFloat = 120
}


extension View {
    func responsiveContentContainer(
        maxWidth: CGFloat = 720,
        compactPadding: CGFloat = 16,
        regularPadding: CGFloat = 28
    ) -> some View {
        modifier(ResponsiveContentContainer(maxWidth: maxWidth, compactPadding: compactPadding, regularPadding: regularPadding))
    }

    func tabbedScrollContentClearance(screen: String) -> some View {
        modifier(TabbedScrollContentClearance(screen: screen))
    }
}

private struct TabbedScrollContentClearance: ViewModifier {
    let screen: String

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: DesignTokens.tabBarContentClearance)
                    .accessibilityHidden(true)
            }
            .onAppear {
                #if DEBUG
                print("[TabSafeArea] applied clearance=\(Int(DesignTokens.tabBarContentClearance)) screen=\(screen)")
                print("[ScrollClearance] bottom content reachable screen=\(screen)")
                #endif
            }
    }
}

private struct ResponsiveContentContainer: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let maxWidth: CGFloat
    let compactPadding: CGFloat
    let regularPadding: CGFloat

    func body(content: Content) -> some View {
        let isRegular = horizontalSizeClass == .regular
        let horizontalPadding = isRegular ? regularPadding : compactPadding

        return content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
            .onAppear {
                #if DEBUG
                if isRegular {
                    print("[ResponsiveUI] sizeClass=regular applying maxWidth=\(Int(maxWidth))")
                }
                #endif
            }
    }
}
