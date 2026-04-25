import SwiftUI
import Foundation

struct PreEventBriefView: View {
    let brief: PreEventBriefBuilder.Brief
    let ctaTitle: String
    let onContinue: (PreEventBriefBuilder.PriorityPerson?) -> Void
    @State private var lastLoggedRecommendationState: String?

    init(
        brief: PreEventBriefBuilder.Brief,
        ctaTitle: String = "Go to event",
        onContinue: @escaping (PreEventBriefBuilder.PriorityPerson?) -> Void
    ) {
        self.brief = brief
        self.ctaTitle = ctaTitle
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Event Brief")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Goal")
                Text(brief.goalLine)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let recommendation = primaryRecommendation {
                    sectionTitle("Live recommendation")
                    recommendationCard(recommendation)
                } else if brief.isLive {
                    sectionTitle("Live recommendation")
                    Text("No strong live match yet.")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text("Check in or wait as more attendees arrive. Nearify updates this brief as stronger signals appear.")
                        .font(.footnote)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    sectionTitle("Live recommendation")
                    Text("Check in to unlock live recommendations based on who’s actually here.")
                        .font(.footnote)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Try this")
                if let recommendation = primaryRecommendation {
                    Text("Start with \(recommendation.name) now while they’re \(recommendation.statusLabel ?? "active").")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if brief.isLive {
                    Text("Check in or wait by high-traffic areas while Nearify updates this brief in real time.")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Check in first, then use this brief to start with the best live match right away.")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                onContinue(primaryRecommendation)
            } label: {
                Text(ctaTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
        .onAppear {
            logRecommendationIfNeeded()
        }
        .onChange(of: recommendationLogState) { _, _ in
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

    private var primaryRecommendation: PreEventBriefBuilder.PriorityPerson? {
        guard brief.isLive else { return nil }
        return brief.priorityPeople.first
    }

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
                    Text("Best person to start with right now")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text(person.name)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if let status = person.statusLabel {
                Text(status == "nearby" ? "Nearby now" : "Currently active")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Why this match")
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

    private func logRecommendationIfNeeded() {
        guard recommendationLogState != lastLoggedRecommendationState else { return }
        lastLoggedRecommendationState = recommendationLogState

        if let person = primaryRecommendation {
            let confidence = String(format: "%.2f", person.confidence ?? 0.0)
            let score = String(format: "%.2f", person.matchScore ?? 0.0)
            print("[Brief] recommendation rendered: \(person.name), confidence=\(confidence), score=\(score), nearby=\(person.isNearby ?? false)")
        } else {
            let reason = brief.isLive ? "no-strong-live-match" : "pre-check-in"
            print("[Brief] no recommendation rendered: \(reason)")
        }
    }
}
