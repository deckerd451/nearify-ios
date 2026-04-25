import SwiftUI

enum VisualStyle {
    static let cardCornerRadius: CGFloat = 20
    static let cardFill = Color.white.opacity(0.05)
    static let cardStroke = Color.white.opacity(0.10)

    static let primaryAction = Color.blue
    static let live = Color.green
    static let intelligence = Color.cyan
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.48)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)
}

struct ElevatedCardModifier: ViewModifier {
    var accent: Color? = nil
    var glow: CGFloat = 0.18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: VisualStyle.cardCornerRadius, style: .continuous)
                    .fill(VisualStyle.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: VisualStyle.cardCornerRadius, style: .continuous)
                            .stroke(VisualStyle.cardStroke, lineWidth: 1)
                    )
                    .shadow(color: (accent ?? .clear).opacity(glow), radius: 14, x: 0, y: 5)
            )
    }
}

extension View {
    func elevatedCard(accent: Color? = nil, glow: CGFloat = 0.18) -> some View {
        modifier(ElevatedCardModifier(accent: accent, glow: glow))
    }
}

struct PressableScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

struct PresencePulseDot: View {
    @State private var animate = false
    var color: Color = VisualStyle.live

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 16, height: 16)
                .scaleEffect(animate ? 1.18 : 0.86)
                .opacity(animate ? 0.15 : 0.45)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
