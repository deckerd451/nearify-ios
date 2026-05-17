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
}


extension View {
    func responsiveContentContainer(
        maxWidth: CGFloat = 720,
        compactPadding: CGFloat = 16,
        regularPadding: CGFloat = 28
    ) -> some View {
        modifier(ResponsiveContentContainer(maxWidth: maxWidth, compactPadding: compactPadding, regularPadding: regularPadding))
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
