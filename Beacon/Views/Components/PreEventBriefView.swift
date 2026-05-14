import SwiftUI
import Foundation

struct PreEventBriefView: View {
    let brief: PreEventBriefBuilder.Brief
    let ctaTitle: String
    let hydrationState: BriefHydrationController.BriefHydrationState
    let onContinue: (PreEventBriefBuilder.PriorityPerson?) -> Void
    @State private var lastLoggedRecommendationState: String?

    init(
        brief: PreEventBriefBuilder.Brief,
        ctaTitle: String = "Go to event",
        hydrationState: BriefHydrationController.BriefHydrationState = .hydrated,
        onContinue: @escaping (PreEventBriefBuilder.PriorityPerson?) -> Void
    ) {
        self.brief = brief
        self.ctaTitle = ctaTitle
        self.hydrationState = hydrationState
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Who's attending")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            if let message = hydrationState.loadingMessage {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("What you want from tonight")
                Text(brief.goalLine)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(brief.goalContextLine)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Who's coming")
                ForEach(Array(brief.joinedSummary.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("You might enjoy meeting")
                if brief.priorityPeople.isEmpty {
                    if hydrationState.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Finding good matches…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("More attendees are joining. Check in when you arrive for live suggestions.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(brief.priorityPeople.prefix(3)) { person in
                        recommendationCard(person)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Break the ice with")
                Text(brief.conversationStarters.first ?? "What kind of project are you hoping to build?")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Text(brief.liveStatusLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Button {
                debugLog("[Brief] dismissing pre-event brief")
                onContinue(nil)
            } label: {
                Text("Got it")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15)))
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            logRecommendationIfNeeded()
        }
        .onChange(of: recommendationLogState) { _ in
            logRecommendationIfNeeded()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.bottom, -2)
    }

    private var primaryRecommendation: PreEventBriefBuilder.PriorityPerson? { brief.priorityPeople.first }

    private var recommendationLogState: String {
        if let person = primaryRecommendation {
            let confidence = String(format: "%.2f", person.confidence ?? 0.0)
            let score = String(format: "%.2f", person.matchScore ?? 0.0)
            return "recommendation:\(person.id.uuidString):\(confidence):\(score):\(person.isNearby ?? false)"
        }
        return brief.isLive ? "no-recommendation:live-none" : "no-recommendation:pre-check-in"
    }

    private func recommendationCard(_ person: PreEventBriefBuilder.PriorityPerson) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AvatarView(
                        imageUrl: person.avatarUrl,
                        name: person.name,
                        size: 40,
                        placeholderColor: .blue
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                if let status = person.statusLabel {
                    Text(status == "nearby" ? "Nearby" : "Active at this event")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Why")
                    Text(person.reason)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.blue.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.35), lineWidth: 1)
        )
    }

    private func hasScoreEvidence(_ person: PreEventBriefBuilder.PriorityPerson) -> Bool {
        (person.confidence ?? 0) > 0 || (person.matchScore ?? 0) > 0
    }

    private func logRecommendationIfNeeded() {
        guard recommendationLogState != lastLoggedRecommendationState else { return }
        lastLoggedRecommendationState = recommendationLogState

        if let person = primaryRecommendation {
            let confidence = String(format: "%.2f", person.confidence ?? 0.0)
            let score = String(format: "%.2f", person.matchScore ?? 0.0)
            print("[Brief] recommendation rendered: \(person.name), confidence=\(confidence), score=\(score), nearby=\(person.isNearby ?? false)")
            #if DEBUG
            if !hasScoreEvidence(person) {
                print("[RecommendationSafety] downgraded zero-confidence recommendation name=\(person.name)")
            }
            #endif
        } else {
            let reason = brief.isLive ? "no-strong-live-match" : "pre-check-in"
            print("[Brief] no recommendation rendered: \(reason)")
        }
    }

    private func firstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}
