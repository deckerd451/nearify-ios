import SwiftUI
import Foundation

struct PreEventBriefView: View {
    enum PresentationMode {
        case preEventPreparation
        case earlyArrival
        case liveNavigation
    }
    let brief: PreEventBriefBuilder.Brief
    let ctaTitle: String
    let hydrationState: BriefHydrationController.BriefHydrationState
    let presentationMode: PresentationMode
    let onContinue: (PreEventBriefBuilder.PriorityPerson?) -> Void
    @State private var lastLoggedRecommendationState: String?
    @State private var selectedRecommendation: PreEventBriefBuilder.PriorityPerson?

    init(
        brief: PreEventBriefBuilder.Brief,
        ctaTitle: String = "Go to event",
        hydrationState: BriefHydrationController.BriefHydrationState = .hydrated,
        presentationMode: PresentationMode = .preEventPreparation,
        onContinue: @escaping (PreEventBriefBuilder.PriorityPerson?) -> Void
    ) {
        self.brief = brief
        self.ctaTitle = ctaTitle
        self.hydrationState = hydrationState
        self.presentationMode = presentationMode
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sheetTitle)
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

            if showsGoalSection {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Your goal tonight")
                    Text(brief.goalLine)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(brief.goalContextLine)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if presentationMode == .earlyArrival {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("No one else is nearby yet")
                    Text("You're early — this is a great time to get comfortable and prepare.")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text("Nearify will surface live people as soon as someone is nearby.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(attendeesSectionTitle)
                ForEach(Array(brief.joinedSummary.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(recommendationSectionTitle)
                if brief.priorityPeople.isEmpty {
                    if hydrationState.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text(loadingCopy)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(emptyRecommendationsCopy)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(brief.priorityPeople.prefix(3)) { person in
                        recommendationCard(person)
                            .onTapGesture { selectedRecommendation = person }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(conversationSectionTitle)
                Text(brief.conversationStarters.first ?? "What kind of project are you hoping to build?")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Text(footerStatusLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Button {
                debugLog("[Brief] dismissing pre-event brief")
                onContinue(nil)
            } label: {
                Text(primaryFooterButtonTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15)))
            }
        }
         .responsiveContentContainer(maxWidth: 680)
        .padding(.vertical, 8)
        .onAppear {
            logRecommendationIfNeeded()
            #if DEBUG
            print("[AttendeeCopy] title=\"\(sheetTitle)\" countType=\(presentationMode == .liveNavigation ? "live" : "joined") count=\(brief.joinedSummary.count)")
            print(briefContentModeLogLine)
            #endif
        }
        .onChange(of: recommendationLogState) { _ in
            logRecommendationIfNeeded()
        }
        .sheet(item: $selectedRecommendation) { person in
            recommendationDetailSheet(person)
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

                if person.statusLabel != nil || person.isNearby != nil {
                    Text(statusCopy(for: person))
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

                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Tap for why + what to say")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
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

    @ViewBuilder
    private func recommendationDetailSheet(_ person: PreEventBriefBuilder.PriorityPerson) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AvatarView(
                        imageUrl: person.avatarUrl,
                        name: person.name,
                        size: 48,
                        placeholderColor: .blue
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(statusCopy(for: person))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Why this person")
                    Text(person.reason)
                        .font(.body)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(detailConversationSectionTitle)
                    Text(conversationStarter(for: person))
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    selectedRecommendation = nil
                    onContinue(person)
                } label: {
                    Text(detailCTA)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                }

                if let secondaryCTA = detailSecondaryCTA {
                    Button {
                        selectedRecommendation = nil
                        onContinue(nil)
                    } label: {
                        Text(secondaryCTA)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }

                if let detailFooter = detailFooterCopy {
                    Text(detailFooter)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .responsiveContentContainer(maxWidth: 640)
            .padding(.vertical, 16)
            .navigationTitle("Meet with confidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        selectedRecommendation = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func conversationStarter(for person: PreEventBriefBuilder.PriorityPerson) -> String {
        if let eventSpecific = brief.conversationStarters.first(where: isEventSpecificStarter) {
            return eventSpecific
        }
        if isSharedContextReason(person.reason) {
            return "Ask what they’re most excited to build or learn at this event."
        }
        return "Ask what brought them here tonight."
    }

    private func isEventSpecificStarter(_ starter: String) -> Bool {
        let text = starter.lowercased()
        let eventSignals = ["event", "tonight", "here", "demo", "talk", "project", "session", "building"]
        return eventSignals.contains(where: { text.contains($0) })
    }

    private func isSharedContextReason(_ reason: String) -> Bool {
        let text = reason.lowercased()
        return text.contains("you both") || text.contains("you've") || text.contains("overlapping") || text.contains("shared")
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


private extension PreEventBriefView {
    var sheetTitle: String {
        switch presentationMode {
        case .preEventPreparation: return "Prepare for this event"
        case .earlyArrival: return "You're early"
        case .liveNavigation: return "Who's here"
        }
    }
    var attendeesSectionTitle: String {
        switch presentationMode {
        case .liveNavigation: return "Who's here"
        case .earlyArrival: return "Likely arriving soon"
        case .preEventPreparation: return "Who's expected"
        }
    }
    var recommendationSectionTitle: String {
        switch presentationMode {
        case .liveNavigation: return "Active now"
        case .earlyArrival: return "People to keep in mind"
        case .preEventPreparation: return "People you may enjoy meeting"
        }
    }
    func statusCopy(for person: PreEventBriefBuilder.PriorityPerson) -> String {
        let isLive = (person.statusLabel == "nearby") || (person.isNearby == true)
        if isLive { return "Here now" }
        switch presentationMode {
        case .liveNavigation: return "Nearby"
        case .earlyArrival: return "Likely arriving soon"
        case .preEventPreparation: return "May be there"
        }
    }
    var detailCTA: String {
        switch presentationMode {
        case .liveNavigation: return "Start Looking"
        case .earlyArrival: return "Keep in mind"
        case .preEventPreparation: return "Keep in mind"
        }
    }
    var detailSecondaryCTA: String? {
        presentationMode == .preEventPreparation ? "Check in when you arrive" : nil
    }
    var detailFooterCopy: String? {
        switch presentationMode {
        case .preEventPreparation: return "Live proximity guidance starts after you check in."
        case .earlyArrival: return "Nearify will switch to live guidance when they’re nearby."
        case .liveNavigation: return nil
        }
    }
    var loadingCopy: String {
        switch presentationMode {
        case .preEventPreparation: return "Building your event preview…"
        case .earlyArrival: return "Checking who may be arriving soon…"
        case .liveNavigation: return "Looking for people nearby…"
        }
    }
    var emptyRecommendationsCopy: String {
        switch presentationMode {
        case .preEventPreparation: return "People are still joining. Keep this event in mind and check in when you arrive."
        case .earlyArrival: return "No strong matches yet. Nearify will suggest people as likely arrivals become clearer."
        case .liveNavigation: return "No one is active nearby right now. Keep moving and Nearify will update live."
        }
    }
    var conversationSectionTitle: String {
        switch presentationMode {
        case .preEventPreparation: return "Conversation ideas"
        case .earlyArrival: return "Easy opener"
        case .liveNavigation: return "Break the ice"
        }
    }
    var detailConversationSectionTitle: String {
        switch presentationMode {
        case .preEventPreparation: return "Possible conversation"
        case .earlyArrival: return "Easy opener"
        case .liveNavigation: return "Conversation starter"
        }
    }
    var showsGoalSection: Bool { presentationMode == .preEventPreparation || presentationMode == .liveNavigation }
    var footerStatusLine: String {
        switch presentationMode {
        case .preEventPreparation: return "Live proximity guidance starts after you check in."
        case .earlyArrival: return "Nearify will switch to live guidance when someone nearby is detected."
        case .liveNavigation: return brief.liveStatusLine
        }
    }
    var primaryFooterButtonTitle: String {
        presentationMode == .liveNavigation ? "Close" : "Got it"
    }
    var briefContentModeLogLine: String {
        switch presentationMode {
        case .preEventPreparation:
            return "[BriefContentMode] mode=preEventPreparation sections=goal,expected,conversationIdeas cta=keepInMind"
        case .earlyArrival:
            return "[BriefContentMode] mode=earlyArrival sections=quietRoom,likelyArrivals,easyOpener cta=keepInMind"
        case .liveNavigation:
            return "[BriefContentMode] mode=liveNavigation sections=nearby,startHere,breakIce cta=startLooking"
        }
    }
}
