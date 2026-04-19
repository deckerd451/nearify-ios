import SwiftUI

/// Presented when the user taps the people CTA but no attendees are active.
/// Clear, visible feedback — not a silent no-op, not an empty list.
struct SoloStateView: View {
    let eventName: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.wave.2")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))

            Text("You're the first one here")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("We'll let you know when someone arrives at \(eventName).")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text("Nearify is still listening for people nearby.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.35))
                .padding(.horizontal, 32)

            Spacer()

            Button {
                #if DEBUG
                print("[SoloState] Dismissed by user")
                #endif
                onDismiss()
            } label: {
                Text("Got it")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            #if DEBUG
            print("[SoloState] Presented for event \(eventName)")
            #endif
        }
    }
}
