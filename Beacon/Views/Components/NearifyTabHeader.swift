import SwiftUI

/// Replaces the system large navigation title on tab root views with a
/// custom header rendered directly in the view hierarchy via safeAreaInset.
///
/// Eliminates iOS 18/19 liquid-glass title compositing failures (titles
/// rendering invisibly on iPhone 17 Pro) by bypassing SwiftUI's large-title
/// propagation entirely. The header is pinned below the safe-area edge,
/// respects Dynamic Island sizing, and has no dependency on UIKit toolbar
/// rendering paths.
///
/// Usage: apply `.nearifyTabHeader("Home")` on the root view inside each
/// tab's NavigationStack instead of `.navigationTitle` + `.navigationBarTitleDisplayMode(.large)`.
/// Pushed detail views re-enable the system bar with `.toolbar(.visible, for: .navigationBar)`.
struct NearifyTabHeader: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .background(Color.black)
            }
    }
}

extension View {
    func nearifyTabHeader(_ title: String) -> some View {
        modifier(NearifyTabHeader(title: title))
    }
}
