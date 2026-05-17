import SwiftUI

/// Presented when the user taps the people CTA but no attendees are active.
/// Clear, visible feedback — not a silent no-op, not an empty list.
struct SoloStateView: View {
    let eventName: String
    let onDismiss: () -> Void
    @ObservedObject private var briefController = BriefHydrationController.shared

    private var likelyPeople: [PreEventBriefBuilder.PriorityPerson] {
        Array((briefController.currentBrief?.priorityPeople ?? []).prefix(3))
    }

    private var conversationStarter: String {
        briefController.currentBrief?.conversationStarters.first
            ?? "Ask what brought them here tonight."
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "person.wave.2")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))

            Text("You’re early — a few people are likely arriving soon.")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text("Here are a few people you may enjoy meeting tonight.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if briefController.hydrationState.isLoading && likelyPeople.isEmpty {
                ProgressView("Preparing your early-arrival brief…")
                    .font(.caption)
                    .tint(.white)
                    .foregroundColor(.white.opacity(0.7))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("People likely arriving soon")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.65))

                    ForEach(likelyPeople) { person in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                                .font(.subheadline)
                                .foregroundColor(.white)
                            Text(person.reason)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(2)
                        }
                    }

                    if likelyPeople.isEmpty {
                        Text("Attendees are still joining \(eventName). You’ll likely recognize people once the event gets going.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                    }

                    Text("Conversation starter: \(conversationStarter)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                #if DEBUG
                print("[SoloState] Dismissed by user")
                #endif
                onDismiss()
            } label: {
                Text("Continue")
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
            if let eventId = EventJoinService.shared.currentEventID.flatMap(UUID.init(uuidString:)),
               briefController.currentBrief == nil {
                briefController.startHydration(eventId: eventId, eventName: eventName)
            }
            #if DEBUG
            print("[SoloState] Presented for event \(eventName)")
            #endif
        }
    }
}
