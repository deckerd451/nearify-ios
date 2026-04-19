import SwiftUI

/// One-time arrival briefing shown when the user joins an event.
/// Wraps EventBriefView with an event name header and dismiss control.
/// Shown once per event session, then replaced by the lighter ongoing EventBriefView.
struct ArrivalBriefView: View {
    let eventName: String
    let brief: EventBrief
    let onTapProfile: (UUID) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with event name + dismiss
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EVENT BRIEF")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.cyan.opacity(0.5))
                        .tracking(0.8)

                    Text(eventName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Text("Got it")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Brief content
            EventBriefView(
                brief: brief,
                onTapProfile: onTapProfile
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }
}
