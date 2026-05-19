import SwiftUI

struct NearifyShellBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.04, green: 0.05, blue: 0.08), Color.black],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [Color.cyan.opacity(0.12), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 480
            )
        )
        .ignoresSafeArea()
    }
}

struct NearifySurfaceCard<Content: View>: View {
    var accent: Color = .white
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(accent.opacity(0.22), lineWidth: 1)
                    )
            )
    }
}

struct NearifyContextChip: View {
    let text: String
    var tint: Color = .white

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(tint.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
