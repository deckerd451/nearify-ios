import SwiftUI
import UIKit

// MARK: - Find Signal State

/// Explicit state machine for the Find Attendee radar.
/// Eliminates contradictory UI by making the signal source unambiguous.
enum FindSignalState: Equatable {
    /// Actively scanning, no BLE match yet, no presence fallback yet
    case searchingForDirectSignal
    /// Direct BLE signal locked — live RSSI guidance available
    case directSignalLocked(rssi: Int, deviceId: UUID)
    /// No direct BLE signal, but attendee is known present via event presence
    case fallbackEventPresence
    /// Had a signal but lost it (device went stale)
    case signalLost
}

enum FindAttendeeSource {
    case brief
    case explore
}

enum FindAttendeeConnectionMode {
    case explore(source: FindAttendeeSource = .explore)
    case briefRecommendation(EventAttendee)

    var source: FindAttendeeSource {
        switch self {
        case .briefRecommendation:
            return .brief
        case .explore(let source):
            return source
        }
    }
}

private enum InteractionPhase: Equatable {
    case active
    case completed
}

/// Find Attendee screen with identity, status block, chips, radar, and signal details
struct FindAttendeeView: View {
    let attendee: EventAttendee
    let connectionMode: FindAttendeeConnectionMode

    @ObservedObject private var stateResolver = AttendeeStateResolver.shared
    @ObservedObject private var scanner = BLEScannerService.shared

    @State private var signalAge: TimeInterval = 0
    @State private var signalTimer: Timer?
    @State private var hadDirectSignal = false
    @State private var didTriggerStrongProximityHaptic = false
    @State private var showConnectionPromptCard = false
    @State private var isSavingConnection = false
    @State private var transientConfirmationMessage: String?
    @State private var interactionPhase: InteractionPhase = .active
    @State private var hasReachedStrongProximity = false
    @State private var completionDebounceStartedAt: Date?
    @State private var hasTriggeredCompletionState = false
    @State private var hasShownSessionConnectionCard = false
    @State private var hasDismissedSessionConnectionCard = false

    @Environment(\.dismiss) private var dismiss

    init(
        attendee: EventAttendee,
        connectionMode: FindAttendeeConnectionMode = .explore()
    ) {
        self.attendee = attendee
        self.connectionMode = connectionMode
    }

    private var presentation: AttendeePresentation {
        stateResolver.resolve(for: attendee)
    }

    private var isBriefRecommendationMode: Bool {
        if case .briefRecommendation = connectionMode { return true }
        return false
    }

    /// The single source of truth for what the radar is showing.
    private var findSignalState: FindSignalState {
        // Try to find the best BLE device for this attendee
        if let device = bestPeerDevice {
            let rssi = scanner.smoothedRSSI(for: device.id) ?? device.rssi
            let age = Date().timeIntervalSince(device.lastSeen)

            if age > 15 {
                // Had a device but it went stale
                return .signalLost
            }

            return .directSignalLocked(rssi: rssi, deviceId: device.id)
        }

        // No BLE device found
        if hadDirectSignal {
            return .signalLost
        }

        // Check if attendee is at least present via event presence
        let presenceAge = Date().timeIntervalSince(attendee.lastSeen)
        if presenceAge < 120 {
            // Scanner is running but no match yet — could still lock
            if scanner.isScanning {
                return .searchingForDirectSignal
            }
            return .fallbackEventPresence
        }

        return .signalLost
    }

    /// Finds the best BLE device for this attendee, collapsing duplicates.
    /// Prefers the freshest device with the strongest RSSI.
    private var bestPeerDevice: DiscoveredBLEDevice? {
        let attendeePrefix = String(attendee.id.uuidString.prefix(8)).lowercased()
        let allDevices = scanner.getFilteredDevices()

        // Collect all BCN- devices matching this attendee's prefix
        let matches = allDevices.filter { device in
            guard let devicePrefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) else {
                return false
            }
            return devicePrefix == attendeePrefix
        }

        guard !matches.isEmpty else { return nil }

        // If multiple matches (duplicate advertisements), pick the freshest with best RSSI
        return matches
            .sorted { a, b in
                let rssiA = scanner.smoothedRSSI(for: a.id) ?? a.rssi
                let rssiB = scanner.smoothedRSSI(for: b.id) ?? b.rssi
                if rssiA != rssiB { return rssiA > rssiB }
                return a.lastSeen > b.lastSeen
            }
            .first
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 16) {
                        identitySection
                        statusBlock
                        if !isBriefRecommendationMode {
                            chipsSection
                        }
                        radarView
                        guidanceCard
                        if !isBriefRecommendationMode {
                            signalDetailsView
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, showConnectionPromptCard ? 120 : 24)
                }

                if showConnectionPromptCard {
                    saveConnectionCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let message = transientConfirmationMessage {
                    Text(message)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.green))
                        .padding(.bottom, showConnectionPromptCard ? 110 : 20)
                        .transition(.opacity)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            startSignalTimer()
            #if DEBUG
            let prefix = String(attendee.id.uuidString.prefix(8)).lowercased()
            print("[FindAttendee] 📡 Opened for: \(attendee.name) (prefix: \(prefix))")
            print("[FindAttendee]   Scanner active: \(scanner.isScanning)")
            print("[FindAttendee]   BLE devices: \(scanner.getFilteredDevices().count)")
            let bcnDevices = scanner.getFilteredDevices().filter { $0.name.hasPrefix("BCN-") }
            print("[FindAttendee]   BCN- devices: \(bcnDevices.map { "\($0.name) RSSI:\($0.rssi)" })")
            print("[FindAttendee]   Initial state: \(findSignalState)")
            #endif
        }
        .onDisappear {
            stopSignalTimer()
        }
        .onChange(of: signalAge) {
            // Track if we ever had a direct signal (for signalLost detection)
            if case .directSignalLocked = findSignalState {
                if !hadDirectSignal {
                    hadDirectSignal = true
                    #if DEBUG
                    print("[FindAttendee] 🔒 Direct BLE lock acquired for \(attendee.name)")
                    #endif
                }
            } else if hadDirectSignal {
                #if DEBUG
                switch findSignalState {
                case .signalLost:
                    print("[FindAttendee] ❌ Direct BLE lock lost for \(attendee.name)")
                case .searchingForDirectSignal:
                    print("[FindAttendee] 🔍 Searching for direct signal — \(attendee.name)")
                case .fallbackEventPresence:
                    print("[FindAttendee] 📍 Fallback to event presence — \(attendee.name)")
                default:
                    break
                }
                #endif
            }

            #if DEBUG
            if case .directSignalLocked(let rssi, let deviceId) = findSignalState {
                // Log current RSSI periodically (every ~4s via signalAge changes)
                let smoothed = scanner.smoothedRSSI(for: deviceId) ?? rssi
                print("[FindAttendee] 📶 RSSI: \(smoothed) dBm for \(attendee.name)")
            }
            #endif

            updateInteractionState()
        }
    }

    private var navigationTitle: String {
        if isBriefRecommendationMode {
            return "Connecting with \(attendee.name)"
        }
        return "Find Attendee"
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        VStack(spacing: 8) {
            AvatarView(
                imageUrl: attendee.avatarUrl,
                name: attendee.name,
                size: 72
            )

            Text(attendee.name)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text(attendee.detailSubtitleText)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Status Block

    private var statusBlock: some View {
        VStack(spacing: 6) {
            connectionLine

            HStack(spacing: 12) {
                Label(identityLabel, systemImage: presentation.relationship.icon)
                    .font(.caption)
                    .foregroundColor(presentation.relationship == .unverified ? .gray : .cyan)

                Label(signalStateLabel, systemImage: signalStateIcon)
                    .font(.caption)
                    .foregroundColor(signalStateColor)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal, 24)
    }

    private var signalStateLabel: String {
        switch findSignalState {
        case .searchingForDirectSignal:
            return "Looking nearby"
        case .directSignalLocked:
            return "Live proximity"
        case .fallbackEventPresence:
            return "Nearby at this event"
        case .signalLost:
            return "Recently nearby"
        }
    }

    private var signalStateIcon: String {
        switch findSignalState {
        case .searchingForDirectSignal:
            return "magnifyingglass"
        case .directSignalLocked:
            return "wave.3.right"
        case .fallbackEventPresence:
            return "antenna.radiowaves.left.and.right"
        case .signalLost:
            return "clock"
        }
    }

    private var signalStateColor: Color {
        switch findSignalState {
        case .searchingForDirectSignal:
            return .yellow
        case .directSignalLocked:
            return .green
        case .fallbackEventPresence:
            return .orange
        case .signalLost:
            return .gray
        }
    }

    private var connectionLine: some View {
        HStack(spacing: 6) {
            Image(systemName: connectionIcon)
                .font(.system(size: 14, weight: .semibold))

            Text(connectionLabel)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .foregroundColor(connectionColor)
    }

    private var connectionLabel: String {
        switch presentation.relationship {
        case .connected:
            return "Connected"
        case .pending:
            return "Connection pending"
        case .metPreviously:
            return "Met previously"
        case .verified, .unverified:
            return "You haven’t met yet"
        }
    }

    private var connectionIcon: String {
        switch presentation.relationship {
        case .connected:
            return "link"
        case .pending:
            return "clock.arrow.circlepath"
        case .metPreviously:
            return "person.crop.circle.badge.clock"
        case .verified, .unverified:
            return "person.crop.circle.badge.minus"
        }
    }

    private var connectionColor: Color {
        switch presentation.relationship {
        case .connected:
            return Color(red: 1.0, green: 0.84, blue: 0.0)
        case .pending:
            return .orange
        case .metPreviously:
            return .purple
        case .verified, .unverified:
            return .gray
        }
    }

    private var identityLabel: String {
        switch presentation.relationship {
        case .connected, .verified, .metPreviously:
            return "Verified attendee"
        case .pending:
            return "Pending verification"
        case .unverified:
            return "Unverified"
        }
    }

    // MARK: - Chips Section

    private var chipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let skills = attendee.skills, !skills.isEmpty {
                Text("Skills")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .textCase(.uppercase)

                WrappingChipsView(tags: skills, color: .blue, maxVisible: 5)
            }

            if let interests = attendee.interests, !interests.isEmpty {
                Text("Interests")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .textCase(.uppercase)

                WrappingChipsView(tags: interests, color: .green, maxVisible: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    // MARK: - Radar View

    private var radarView: some View {
        ZStack {
            ForEach([190.0, 140.0, 90.0, 56.0], id: \.self) { size in
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .frame(width: size, height: size)
            }

            Circle()
                .fill(signalColor.opacity(0.3))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .fill(signalColor)
                        .frame(width: 10, height: 10)
                )
                .offset(radarOffset)
                .animation(.easeInOut(duration: 1.0), value: radarOffset)
        }
        .frame(height: 200)
    }

    private var radarOffset: CGSize {
        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            // No direct signal — place dot at outer edge
            return CGSize(width: 60, height: -40)
        }

        let norm = max(0, min(1, Double(rssi + 90) / 50.0))
        let distance = 80.0 * (1.0 - norm)

        return CGSize(width: distance * 0.7, height: -distance * 0.5)
    }

    // MARK: - Guidance Card

    private var guidanceCard: some View {
        VStack(spacing: 8) {
            if isBriefRecommendationMode {
                Text("Recommended for you")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.cyan.opacity(0.75))
            }

            if interactionPhase == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)

                Text("You just crossed paths with \(attendee.name)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)

                Text("Wrap up when you're ready.")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            } else {
                switch findSignalState {
                case .directSignalLocked(let rssi, let deviceId):
                    let trend = rssiTrend(for: deviceId) ?? 0

                    Text(proximityHeadline(rssi: rssi, trend: trend))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(signalColor)

                    Text(movementSuggestion(rssi: rssi, trend: trend))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    conversationBridge(rssi: rssi)

                case .searchingForDirectSignal:
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.yellow)

                    Text(isBriefRecommendationMode ? "Connecting now" : "They’re somewhere nearby")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.yellow)

                    Text(isBriefRecommendationMode ? "Walk naturally and look around — this is a good moment to approach." : "Move around naturally while Nearify keeps looking.")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                case .fallbackEventPresence:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundColor(.orange)

                    Text(isBriefRecommendationMode ? "They’re nearby" : "Using event presence")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)

                    Text(isBriefRecommendationMode ? "You can start walking over now while we refine their direction." : "They’re active at this event — walk naturally and look around.")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                case .signalLost:
                    Image(systemName: "wifi.slash")
                        .font(.title2)
                        .foregroundColor(.gray)

                    Text("They may have moved")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.gray)

                    Text("They may have moved — try looking around naturally")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Guidance Helpers

    private func proximityHeadline(rssi: Int, trend: Int) -> String {
        if rssi >= -45 {
            return "They’re very close"
        }
        if trend > 2 {
            return "You’re getting closer"
        }
        return "They’re somewhere nearby"
    }

    private func movementSuggestion(rssi: Int, trend: Int) -> String {
        if rssi >= -45 {
            return "This is a good moment to say hi"
        }
        if rssi >= -55, trend > 2 {
            return "Keep going — you’re almost there"
        }
        if trend > 2 {
            return "You’re headed the right way"
        }
        if trend >= -2, trend <= 2 {
            return "Pause and scan the room naturally"
        }
        return "Try a different direction and look around"
    }

    @ViewBuilder
    private func conversationBridge(rssi: Int) -> some View {
        if rssi >= -45 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open with:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.85))
                Text("• What brought you here?")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Text("• What are you working on right now?")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Signal Details

    private var signalDetailsView: some View {
        VStack(spacing: 6) {
            if interactionPhase == .completed {
                Text("Interaction complete")
                    .font(.caption2)
                    .foregroundColor(.green.opacity(0.7))
            } else {
                switch findSignalState {
                case .directSignalLocked(let rssi, _):
                    HStack(spacing: 14) {
                        Label("\(rssi) dBm", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundColor(signalColor.opacity(0.7))

                        Label(trendLabel, systemImage: "arrow.up.arrow.down")
                            .font(.caption2)
                            .foregroundColor(trendColor.opacity(0.7))
                    }

                    Text("Live BLE signal detected")
                        .font(.caption2)
                        .foregroundColor(.green.opacity(0.6))

                case .searchingForDirectSignal:
                    Text("Looking for their live signal…")
                        .font(.caption2)
                        .foregroundColor(.yellow.opacity(0.6))

                case .fallbackEventPresence:
                    Text("They’re active at this event — refining direction")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.6))

                case .signalLost:
                    Text("Last seen nearby — keep looking around naturally")
                        .font(.caption2)
                        .foregroundColor(.gray.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Helpers

    private var signalColor: Color {
        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            return .gray
        }

        switch rssi {
        case -45...0:
            return .green
        case -65 ..< -45:
            return .blue
        case -80 ..< -65:
            return .orange
        default:
            return .red
        }
    }

    private var trendLabel: String {
        guard case .directSignalLocked(_, let deviceId) = findSignalState,
              let trend = rssiTrend(for: deviceId) else {
            return "—"
        }

        if trend > 2 { return "Approaching" }
        if trend < -2 { return "Moving away" }
        return "Stable"
    }

    private var trendColor: Color {
        guard case .directSignalLocked(_, let deviceId) = findSignalState,
              let trend = rssiTrend(for: deviceId) else {
            return .gray
        }

        if trend > 2 { return .green }
        if trend < -2 { return .orange }
        return .gray
    }

    private func rssiTrend(for deviceId: UUID) -> Int? {
        guard let current = scanner.smoothedRSSI(for: deviceId),
              let device = scanner.discoveredDevices[deviceId] else {
            return nil
        }

        return current - device.rssi
    }

    private func startSignalTimer() {
        stopSignalTimer()

        signalTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                signalAge = Date().timeIntervalSinceReferenceDate
            }
        }
    }

    private func stopSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = nil
    }

    private func updateInteractionState() {
        let now = Date()
        let isStrongSignal = isCurrentSignalStrong

        if interactionPhase == .completed {
            return
        }

        if isStrongSignal {
            hasReachedStrongProximity = true
            completionDebounceStartedAt = nil
            triggerStrongProximityFeedbackIfNeeded()
            return
        }

        didTriggerStrongProximityHaptic = false

        guard hasReachedStrongProximity else {
            return
        }

        if completionDebounceStartedAt == nil {
            completionDebounceStartedAt = now
            return
        }

        guard let debounceStartedAt = completionDebounceStartedAt else { return }
        guard now.timeIntervalSince(debounceStartedAt) >= 8 else { return }
        enterCompletedInteractionState()
    }

    private var isCurrentSignalStrong: Bool {
        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            return false
        }
        return rssi >= -45
    }

    private func enterCompletedInteractionState() {
        guard !hasTriggeredCompletionState else { return }
        hasTriggeredCompletionState = true
        interactionPhase = .completed
        showConnectionPromptCard = false

        guard !hasDismissedSessionConnectionCard else { return }
        guard !ConnectionPromptStateStore.shared.isSaved(profileId: attendee.id, eventId: currentEventId) else { return }
        guard !hasShownSessionConnectionCard else { return }

        hasShownSessionConnectionCard = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            showConnectionPromptCard = true
        }
    }

    private func triggerStrongProximityFeedbackIfNeeded() {
        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            didTriggerStrongProximityHaptic = false
            return
        }

        guard rssi >= -45 else {
            didTriggerStrongProximityHaptic = false
            return
        }

        guard !didTriggerStrongProximityHaptic else { return }
        didTriggerStrongProximityHaptic = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private var currentEventId: String? {
        EventJoinService.shared.currentEventID
    }

    private var saveConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save connection with \(attendee.name)")
                .font(.subheadline)
                .foregroundColor(.white)

            HStack(spacing: 10) {
                Button {
                    saveConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isSavingConnection {
                            ProgressView().tint(.black)
                        }
                        Text("Save Connection")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green)
                    .foregroundColor(.black)
                    .cornerRadius(10)
                }
                .disabled(isSavingConnection)

                Button("Dismiss") {
                    hasDismissedSessionConnectionCard = true
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showConnectionPromptCard = false
                    }
                }
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .disabled(isSavingConnection)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
    }

    private func saveConnection() {
        guard !isSavingConnection else { return }
        isSavingConnection = true

        Task {
            do {
                _ = try await ConnectionService.shared.createConnectionIfNeeded(to: attendee.id.uuidString)
                ConnectionPromptStateStore.shared.markSaved(profileId: attendee.id, eventId: currentEventId)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showConnectionPromptCard = false
                        transientConfirmationMessage = "Connection saved"
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        transientConfirmationMessage = nil
                    }
                }
            } catch {
                #if DEBUG
                print("[FindAttendee] Failed to save connection for \(attendee.name): \(error.localizedDescription)")
                #endif
            }

            await MainActor.run {
                isSavingConnection = false
            }
        }
    }
}
