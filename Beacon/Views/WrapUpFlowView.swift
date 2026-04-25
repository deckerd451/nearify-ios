import SwiftUI
import MessageUI

/// Single-screen Say Goodbye flow.
/// Shows the top connections from the event with one action per person.
/// No multi-step summary. No duplicate people. Action-oriented copy.
struct WrapUpFlowView: View {
    let eventName: String
    let onComplete: () async -> Void

    @State private var people: [WrapUpPerson] = []
    @State private var strongCandidateNames: [String] = []
    @State private var shareState: ShareState = .hidden
    @State private var showShareOptions = false
    @State private var showMessageComposer = false
    @State private var activeConversation: WrapUpConversation?
    @State private var isOpeningConversation = false
    @State private var profileTarget: WrapUpProfileTarget?
    @State private var isNavigatingToProfile = false
    @State private var isWrappingUpEvent = false
    @State private var wrapUpTask: Task<Void, Never>?

    private enum ShareState: Equatable {
        case hidden             // No strong candidates or share not applicable
        case offered            // Prompt visible, user hasn't acted
        case completed(String)  // Share sent via a specific method (sender-side only)
        case skipped            // User tapped Skip or cancelled
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        Spacer().frame(height: 32)

                        // Header — action-oriented, not summary-oriented
                        header

                        Spacer().frame(height: 28)

                        if people.isEmpty {
                            emptyState
                        } else {
                            // Top connections — deduplicated, ranked, max 3
                            VStack(spacing: 12) {
                                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                                    personCard(person, rank: index)
                                }
                            }
                            .padding(.horizontal)
                        }

                        Spacer().frame(height: 36)

                        // Optional share prompt — only for strong candidates
                        if case .offered = shareState {
                            sharePrompt
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else if case .completed(let method) = shareState {
                            shareConfirmation(method: method)
                                .transition(.opacity)
                        }

                        Spacer().frame(height: shareState == .hidden || shareState == .skipped ? 0 : 12)

                        // Single exit button
                        finishButton

                        Spacer().frame(height: 16)
                    }
                }
                .allowsHitTesting(!isWrappingUpEvent)

                if isOpeningConversation {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).scaleEffect(1.2)
                        Text("Opening conversation…")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                }

                if isWrappingUpEvent {
                    wrappingUpOverlay
                }

            }
            .navigationTitle("Say Goodbye")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.gray)
                        .disabled(isWrappingUpEvent)
                }
            }
            .sheet(item: $activeConversation) { dest in
                ConversationView(
                    targetProfileId: dest.profileId,
                    preloadedConversation: dest.conversation,
                    preloadedName: dest.name
                )
            }
            .sheet(item: $profileTarget, onDismiss: {
                isNavigatingToProfile = false
            }) { target in
                NavigationStack {
                    FeedProfileDetailView(profileId: target.profileId)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button {
                                    profileTarget = nil
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                }
            }
        }
        .onAppear { loadPeople() }
        .onDisappear {
            wrapUpTask?.cancel()
            wrapUpTask = nil
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, isWrappingUpEvent else { return }
            wrapUpTask?.cancel()
            wrapUpTask = nil
            isWrappingUpEvent = false
        }
        .sheet(isPresented: $showMessageComposer) {
            MessageComposerView(
                body: shareMessageBody,
                onFinished: { sent in
                    showMessageComposer = false
                    if sent {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            shareState = .completed("Messages")
                        }
                    }
                    // If cancelled, stay on .offered so user can try another method
                }
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            Text("Take your best connections with you")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if !people.isEmpty {
                Text("from \(eventName)")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.3))

            Text("No interactions to save")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))

            Text("You can still leave the event")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 32)
    }

    // MARK: - Person Card

    private func personCard(_ person: WrapUpPerson, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Rank indicator for the top person
                if rank == 0 {
                    ZStack {
                        AvatarView(
                            imageUrl: person.avatarUrl,
                            name: person.name,
                            size: 52,
                            placeholderColor: .orange
                        )

                        // Subtle top-connection ring
                        Circle()
                            .stroke(Color.orange.opacity(0.4), lineWidth: 2)
                            .frame(width: 56, height: 56)
                    }
                } else {
                    AvatarView(
                        imageUrl: person.avatarUrl,
                        name: person.name,
                        size: 48,
                        placeholderColor: .cyan
                    )
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text(person.reason)
                        .font(.caption)
                        .foregroundColor(rank == 0 ? .orange.opacity(0.8) : .gray)
                        .lineLimit(2)
                }

                Spacer()
            }

            // One primary action + one secondary
            HStack(spacing: 8) {
                Button {
                    openMessage(profileId: person.id, name: person.name)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left").font(.caption2)
                        Text("Message").font(.caption).fontWeight(.medium)
                    }
                    .foregroundColor(rank == 0 ? .orange : .cyan)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background((rank == 0 ? Color.orange : Color.cyan).opacity(0.12))
                    .cornerRadius(8)
                }

                Button {
                    openProfile(for: person.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person").font(.caption2)
                        Text("Profile").font(.caption).fontWeight(.medium)
                    }
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                }

                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(rank == 0 ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(rank == 0 ? Color.orange.opacity(0.15) : Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }

    // MARK: - Share Prompt

    private var sharePrompt: some View {
        VStack(spacing: 12) {
            let names = strongCandidateNames
            let nameText: String = {
                switch names.count {
                case 1: return names[0]
                case 2: return "\(names[0]) and \(names[1])"
                case 3: return "\(names[0]), \(names[1]), and \(names[2])"
                default: return "your strongest connections"
                }
            }()

            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .foregroundColor(.cyan.opacity(0.7))

                Text("Share your profile with \(nameText)?")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shareState = .skipped
                    }
                    #if DEBUG
                    print("[ShareNow] user skipped share prompt")
                    #endif
                } label: {
                    Text("Skip")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                }

                Button {
                    showShareOptions = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("Share Now")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.cyan)
                    .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 32)
        .confirmationDialog(
            "Share with \(strongCandidateNames.first ?? "them")",
            isPresented: $showShareOptions,
            titleVisibility: .visible
        ) {
            Button {
                handleShareViaAirDrop()
            } label: {
                Label("AirDrop — Fastest if they're nearby", systemImage: "airplayaudio")
            }

            if MFMessageComposeViewController.canSendText() {
                Button {
                    showMessageComposer = true
                } label: {
                    Label("Message — Send via text", systemImage: "message")
                }
            }

            Button {
                handleShareViaSheet()
            } label: {
                Label("More options", systemImage: "ellipsis.circle")
            }

            Button("Cancel", role: .cancel) {}
        }
    }

    private func shareConfirmation(method: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.cyan)
            Text("Share sent via \(method)")
                .font(.caption)
                .foregroundColor(.cyan.opacity(0.8))
        }
        .padding(.horizontal, 32)
    }

    private func handleShareViaAirDrop() {
        #if DEBUG
        print("[ShareNow] user chose AirDrop")
        #endif
        let presented = ShareNowService.presentShareSheet { result in
            withAnimation(.easeInOut(duration: 0.2)) {
                switch result {
                case .completed(let activityType):
                    shareState = .completed(activityType)
                case .cancelled, .failed:
                    // Return to offered state so user can try again
                    shareState = .offered
                }
            }
        }
        if !presented {
            shareState = .offered
        }
    }

    private func handleShareViaSheet() {
        #if DEBUG
        print("[ShareNow] user chose More options")
        #endif
        let presented = ShareNowService.presentShareSheet { result in
            withAnimation(.easeInOut(duration: 0.2)) {
                switch result {
                case .completed(let activityType):
                    shareState = .completed(activityType)
                case .cancelled, .failed:
                    shareState = .offered
                }
            }
        }
        if !presented {
            shareState = .offered
        }
    }

    /// Pre-built message body for the SMS composer.
    private var shareMessageBody: String {
        guard let user = AuthService.shared.currentUser else { return "" }
        let deepLink = "beacon://profile/\(user.id.uuidString)"
        let installURL = AppEnvironment.nearifyShareInstallURL.absoluteString
        return "Nice meeting you — here's my Nearify profile:\n\(deepLink)\n\nGet Nearify:\n\(installURL)"
    }

    // MARK: - Finish Button

    private var finishButton: some View {
        Button {
            finishWrapUp()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text("Finish and save for later")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.orange)
            .foregroundColor(.black)
            .cornerRadius(14)
        }
        .padding(.horizontal, 32)
        .disabled(isWrappingUpEvent)
        .opacity(isWrappingUpEvent ? 0.6 : 1.0)
    }

    // MARK: - Profile Navigation

    private func openProfile(for personId: UUID) {
        guard !isNavigatingToProfile else { return }
        guard profileTarget?.profileId != personId else { return }
        isNavigatingToProfile = true
        profileTarget = WrapUpProfileTarget(profileId: personId)
    }

    // MARK: - Data Loading

    @MainActor
    private func loadPeople() {
        let eventUUID = EventJoinService.shared.currentEventID.flatMap { UUID(uuidString: $0) }
        let rankedIntents = TransferIntentRanker.rank(forEvent: eventUUID)

        // Primary path: use ranked local encounter data when available.
        // Only use intents that have a resolved profile (name + ID).
        let resolved = rankedIntents.filter { $0.resolvedProfileId != nil && $0.resolvedName != nil }

        if !resolved.isEmpty {
            people = buildFromRankedIntents(resolved)
            #if DEBUG
            print("[WrapUp] loaded \(people.count) people from TransferIntent ranker")
            for p in people { print("[WrapUp]   \(p.name): \(p.reason)") }
            #endif
        } else {
            // Fallback: use existing relationship + attendee scoring when the
            // ranker has no resolved candidates.
            #if DEBUG
            print("[WrapUp] ranker produced no resolved candidates — falling back to relationship data")
            #endif
            people = buildFromRelationships()
        }

        // Determine Share Now eligibility.
        // Path 1: strong encounter from the ranker (existing logic)
        // Path 2: strong existing relationship AND detected at current event
        var eligibleNames: [String] = []

        // Path 1: strong ranked encounters
        let strongFromRanker = rankedIntents.filter {
            $0.eligibleForRelease && $0.resolvedName != nil
        }
        for intent in strongFromRanker.prefix(3) {
            if let name = intent.resolvedName {
                eligibleNames.append(name)
                #if DEBUG
                print("[ShareNow] eligible via encounter: \(name)")
                #endif
            }
        }

        // Path 2: strong relationship + present at event
        // Only add people not already eligible from Path 1
        let eligibleIds = Set(strongFromRanker.compactMap(\.resolvedProfileId))
        let relationships = RelationshipMemoryService.shared.relationships
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let attendeeIds = Set(EventAttendeesService.shared.attendees.map(\.id))
        let bleDevices = BLEScannerService.shared.getFilteredDevices()
        var blePrefixes = Set<String>()
        for device in bleDevices where device.name.hasPrefix("BCN-") {
            if let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) {
                blePrefixes.insert(prefix)
            }
        }

        for rel in relationships {
            guard eligibleNames.count < 3 else { break }
            guard !eligibleIds.contains(rel.profileId) else { continue }

            // Must have a strong relationship: connected OR significant history
            let isConnected = connectedIds.contains(rel.profileId)
            let hasSignificantHistory = rel.totalOverlapSeconds >= 120 || rel.encounterCount >= 3
            guard isConnected || hasSignificantHistory else {
                #if DEBUG
                print("[ShareNow] not eligible: \(rel.name) reason=weak relationship (connected=\(isConnected), overlap=\(rel.totalOverlapSeconds)s, encounters=\(rel.encounterCount))")
                #endif
                continue
            }

            // Must be detected at current event (attendee list OR BLE)
            let inAttendeeList = attendeeIds.contains(rel.profileId)
            let relPrefix = String(rel.profileId.uuidString.prefix(8)).lowercased()
            let isBLEDetected = blePrefixes.contains(relPrefix)
            guard inAttendeeList || isBLEDetected else {
                #if DEBUG
                print("[ShareNow] not eligible: \(rel.name) reason=not detected at event (attendee=\(inAttendeeList), ble=\(isBLEDetected))")
                #endif
                continue
            }

            eligibleNames.append(rel.name)
            #if DEBUG
            let source = inAttendeeList ? "attendee list" : "BLE"
            print("[ShareNow] eligible via relationship: \(rel.name) (connected=\(isConnected), detected via \(source))")
            #endif
        }

        if !eligibleNames.isEmpty {
            strongCandidateNames = eligibleNames
            shareState = .offered
            #if DEBUG
            print("[ShareNow] share prompt offered for: \(strongCandidateNames.joined(separator: ", "))")
            #endif
        } else {
            shareState = .hidden
        }
    }

    /// Builds WrapUpPerson list from ranked TransferIntents, enriched with
    /// relationship data for better reason lines.
    private func buildFromRankedIntents(_ intents: [TransferIntentRanker.TransferIntent]) -> [WrapUpPerson] {
        let relationships = RelationshipMemoryService.shared.relationships
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let encounters = EncounterService.shared.activeEncounters
        var seenIds = Set<UUID>()

        return intents.prefix(3).compactMap { intent -> WrapUpPerson? in
            guard let profileId = intent.resolvedProfileId,
                  let name = intent.resolvedName else { return nil }
            guard !seenIds.contains(profileId) else { return nil }
            seenIds.insert(profileId)

            let rel = relationships.first { $0.profileId == profileId }
            let isConnected = connectedIds.contains(profileId)
            let sessionEnc = encounters[profileId]

            let reason = buildRankedReason(
                intent: intent,
                relationship: rel,
                isConnected: isConnected,
                sessionEncounter: sessionEnc
            )

            return WrapUpPerson(
                id: profileId,
                name: name,
                avatarUrl: intent.resolvedAvatarUrl ?? rel?.avatarUrl,
                reason: reason
            )
        }
    }

    /// Builds a reason line from ranked intent data + relationship context.
    /// Grounded in real signals — duration, signal quality, connection status, interests.
    private func buildRankedReason(
        intent: TransferIntentRanker.TransferIntent,
        relationship: RelationshipMemory?,
        isConnected: Bool,
        sessionEncounter: EncounterTracker?
    ) -> String {
        let minutes = intent.score > 0
            ? max(
                (sessionEncounter?.totalSeconds ?? 0) / 60,
                // Use the local encounter duration from the ranker's source data
                LocalEncounterStore.shared.allEncounters
                    .first { $0.peerEphemeralId == intent.peerPrefix }
                    .map { $0.duration / 60 } ?? 0
              )
            : 0

        // Shared interests — most specific framing
        if let interests = relationship?.sharedInterests, let first = interests.first, !first.isEmpty {
            if isConnected {
                return "Connected · both into \(first)"
            }
            if minutes >= 2 {
                return "Both into \(first) · \(minutes) min together"
            }
            return "Both into \(first)"
        }

        // Strong encounters — emphasize the quality of the interaction
        if intent.priorityLevel == .strong {
            if isConnected && minutes >= 2 {
                return "Your strongest connection · \(minutes) min together"
            }
            if isConnected {
                return "Connected · strongest signal at the event"
            }
            if minutes >= 5 {
                return "\(minutes) min together · your strongest encounter"
            }
            if minutes >= 2 {
                return "\(minutes) min together · strong signal"
            }
            return "Strongest encounter at the event"
        }

        // Connected but not strong — emphasize follow-up value
        if isConnected {
            if let rel = relationship, !rel.hasConversation {
                return "Connected · haven't messaged yet"
            }
            if minutes > 0 {
                return "Connected · \(minutes) min together"
            }
            return "Connected · keep the conversation going"
        }

        // Medium encounters — emphasize the time spent
        if intent.priorityLevel == .medium {
            if minutes >= 2 {
                return "\(minutes) min together · worth connecting"
            }
            return "Meaningful encounter · say hi before you go"
        }

        // Repeat encounters from relationship history
        if let rel = relationship, rel.encounterCount >= 3 {
            return "Crossed paths \(rel.encounterCount) times"
        }

        // Weak / fallback
        if minutes > 0 {
            return "\(minutes) min nearby"
        }
        return "Met at \(eventName)"
    }

    /// Fallback: builds people list from existing relationship + attendee data
    /// when the ranker has no resolved candidates.
    private func buildFromRelationships() -> [WrapUpPerson] {
        let encounters = EncounterService.shared.activeEncounters
        let relationships = RelationshipMemoryService.shared.relationships
        let connectedIds = AttendeeStateResolver.shared.connectedIds
        let myId = AuthService.shared.currentUser?.id

        var scored: [(id: UUID, name: String, avatarUrl: String?, score: Double, reason: String)] = []
        var seenIds = Set<UUID>()

        for rel in relationships {
            guard rel.profileId != myId, !seenIds.contains(rel.profileId) else { continue }

            let sessionTime = Double(encounters[rel.profileId]?.totalSeconds ?? 0)
            let historicalTime = Double(rel.totalOverlapSeconds)
            let isConnected = connectedIds.contains(rel.profileId)
            let eventMatch = rel.eventContexts.contains(eventName) || encounters[rel.profileId] != nil

            guard eventMatch else { continue }

            let repeatBonus = Double(rel.encounterCount) * 30.0
            let connectionBonus: Double = isConnected ? 60.0 : 0
            let score = sessionTime + historicalTime * 0.5 + repeatBonus + connectionBonus
            guard score > 0 else { continue }

            seenIds.insert(rel.profileId)

            let totalSecs = max(rel.totalOverlapSeconds, Int(sessionTime))
            let mins = totalSecs / 60
            let reason = buildReason(
                name: rel.name,
                minutes: mins,
                encounterCount: rel.encounterCount,
                isConnected: isConnected,
                hasConversation: rel.hasConversation,
                sharedInterests: rel.sharedInterests
            )

            scored.append((rel.profileId, rel.name, rel.avatarUrl, score, reason))
        }

        let attendees = EventAttendeesService.shared.attendees
        for attendee in attendees {
            guard attendee.id != myId, !seenIds.contains(attendee.id) else { continue }
            guard let enc = encounters[attendee.id], enc.totalSeconds > 0 else { continue }

            seenIds.insert(attendee.id)
            let mins = enc.totalSeconds / 60
            let isConnected = connectedIds.contains(attendee.id)
            let reason = buildReason(
                name: attendee.name,
                minutes: mins,
                encounterCount: 1,
                isConnected: isConnected,
                hasConversation: false,
                sharedInterests: []
            )

            scored.append((attendee.id, attendee.name, attendee.avatarUrl, Double(enc.totalSeconds), reason))
        }

        scored.sort { $0.score > $1.score }

        return scored.prefix(3).map { item in
            WrapUpPerson(
                id: item.id,
                name: item.name,
                avatarUrl: item.avatarUrl,
                reason: item.reason
            )
        }
    }

    /// Builds a single concise reason line. Priority:
    /// 1. Shared interest overlap
    /// 2. Time together
    /// 3. Connection status
    /// 4. Repeat encounters
    private func buildReason(
        name: String,
        minutes: Int,
        encounterCount: Int,
        isConnected: Bool,
        hasConversation: Bool,
        sharedInterests: [String]
    ) -> String {
        // Shared interests — most specific and valuable
        if let interest = sharedInterests.first, !interest.isEmpty {
            if isConnected {
                return "Connected · both into \(interest)"
            }
            return "Both into \(interest) · \(minutes > 0 ? "\(minutes) min together" : "nearby")"
        }

        // Time together — concrete and meaningful
        if minutes >= 5 && isConnected {
            return "Connected · \(minutes) min together"
        }
        if minutes >= 5 {
            return "\(minutes) min together · worth connecting"
        }

        // Connection status
        if isConnected && !hasConversation {
            return "Connected · haven't messaged yet"
        }
        if isConnected {
            return "Connected · keep the conversation going"
        }

        // Repeat encounters
        if encounterCount >= 3 {
            return "Crossed paths \(encounterCount) times"
        }
        if minutes > 0 {
            return "\(minutes) min nearby · say hi before you go"
        }

        return "Met at \(eventName)"
    }

    // MARK: - Flow Control

    private func finishWrapUp() {
        guard !isWrappingUpEvent else { return }
        isWrappingUpEvent = true

        wrapUpTask = Task {
            await onComplete()
            await MainActor.run {
                isWrappingUpEvent = false
            }
        }
    }

    private var wrappingUpOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.25)

                Text("Wrapping up your event…")
                    .font(.headline)
                    .foregroundColor(.white)

                Text("Finalizing your connections and summary")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .cornerRadius(16)
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Messaging

    @MainActor
    private func openMessage(profileId: UUID, name: String) {
        guard !isOpeningConversation else { return }
        isOpeningConversation = true

        Task {
            do {
                let convo = try await MessagingService.shared.getOrCreateConversation(with: profileId)
                await MessagingService.shared.fetchMessages(conversationId: convo.id)
                await MainActor.run {
                    activeConversation = WrapUpConversation(
                        profileId: profileId, name: name, conversation: convo
                    )
                    isOpeningConversation = false
                }
            } catch {
                await MainActor.run {
                    isOpeningConversation = false
                    #if DEBUG
                    print("[WrapUp] ⚠️ Conversation open failed: \(error)")
                    #endif
                }
            }
        }
    }
}

// MARK: - Message Composer

/// Wraps MFMessageComposeViewController for SwiftUI presentation.
struct MessageComposerView: UIViewControllerRepresentable {
    let body: String
    let onFinished: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinished: (Bool) -> Void

        init(onFinished: @escaping (Bool) -> Void) {
            self.onFinished = onFinished
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            let sent = result == .sent
            #if DEBUG
            switch result {
            case .sent:      print("[ShareNow] message sent")
            case .cancelled: print("[ShareNow] message cancelled")
            case .failed:    print("[ShareNow] message failed")
            @unknown default: print("[ShareNow] message unknown result")
            }
            #endif
            onFinished(sent)
        }
    }
}

// MARK: - Supporting Types

struct WrapUpPerson: Identifiable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let reason: String
}

private struct WrapUpConversation: Identifiable {
    let id = UUID()
    let profileId: UUID
    let name: String
    let conversation: Conversation
}

private struct WrapUpProfileTarget: Identifiable {
    var id: UUID { profileId }
    let profileId: UUID
}
