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

enum FindState: Equatable {
    case searching
    case locked(rssi: Int)
    case arrived
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

/// Find Attendee screen with identity, status block, chips, radar, and signal details
struct FindAttendeeView: View {
    let attendee: EventAttendee
    let connectionMode: FindAttendeeConnectionMode

    @ObservedObject private var stateResolver = AttendeeStateResolver.shared
    @ObservedObject private var scanner = BLEScannerService.shared

    @State private var signalAge: TimeInterval = 0
    @State private var signalTimer: Timer?
    @State private var hadDirectSignal = false
    @State private var findState: FindState = .searching
    @State private var proximityLockStartedAt: Date?
    @State private var arrivedRSSI: Int?
    @State private var hasTriggeredArrivedHaptic = false
    @State private var isSavingConnection = false
    @State private var isCheckingConnectionStatus = false
    @State private var isAlreadyConnected = false
    @State private var hasSavedConnection = false
    @State private var transientConfirmationMessage: String?
    @State private var viewAppearedAt: Date?
    @State private var hasEnteredExtendedSearchState = false
    @State private var isSearchExpanded = false
    @State private var ambientMessageIndex = 0
    @State private var ambientMessageTask: Task<Void, Never>?
    @State private var showContactSaveSheet = false

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
                        searchAnchor
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
                    .padding(.bottom, 24)
                }

                if let message = transientConfirmationMessage {
                    Text(message)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.green))
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Back to event") { dismiss() }
            }
        }
        .onAppear {
            viewAppearedAt = Date()
            startSignalTimer()
            startAmbientMessageRotation()
            hasSavedConnection = ConnectionPromptStateStore.shared.isSaved(profileId: attendee.id, eventId: currentEventId)
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
            stopAmbientMessageRotation()
        }
        .sheet(isPresented: $showContactSaveSheet) {
            ContactSaveSheet(draft: attendeeContactDraft) { didSave in
                showContactSaveSheet = false
                guard didSave else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    transientConfirmationMessage = "Saved to your contacts with context from Nearify"
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            transientConfirmationMessage = nil
                        }
                    }
                }
            }
        }
        .onChange(of: signalAge) {
            guard findState != .arrived else { return }

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

            updateAdaptiveSearchState()
            updateFindState()
        }
    }

    private var navigationTitle: String {
        if isBriefRecommendationMode {
            return "Connecting with \(attendee.name)"
        }
        return "Find Attendee"
    }

    // MARK: - Identity Section

    private var searchAnchor: some View {
        HStack(spacing: 6) {
            Text("Looking for:")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.9))
            Text(attendee.name)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
    }

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

            Text(presenceCueText)
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
        if findState == .arrived {
            return "Arrived"
        }
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
        if findState == .arrived {
            return "checkmark.seal.fill"
        }
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
        if findState == .arrived {
            return .green
        }
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
                    .stroke(Color.white.opacity(findState == .arrived ? 0.03 : 0.08), lineWidth: 1)
                    .frame(width: size, height: size)
            }

            if findState == .arrived {
                Circle()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: 140, height: 140)
                    .blur(radius: 8)
            } else {
                directionalBiasGlow
                radarPulse
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
                .animation(findState == .arrived ? nil : .easeInOut(duration: 1.0), value: radarOffset)
        }
        .frame(height: 200)
    }

    private var radarPulse: some View {
        TimelineView(.animation) { context in
            let duration = pulseDuration
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let organicVariance = 1 + (sin(elapsed * 0.41) * 0.08)
            let cycle = elapsed.truncatingRemainder(dividingBy: duration * organicVariance) / (duration * organicVariance)
            let tightened = isGettingCloserMoment ? 0.88 : 1.0

            ZStack {
                Circle()
                    .fill(signalColor.opacity(0.11 + (signalIntensity * 0.1)))
                    .frame(width: 26, height: 26)
                    .blur(radius: isGettingCloserMoment ? 1 : 2)

                ForEach([0.0, 0.33, 0.66], id: \.self) { phase in
                    let phasedCycle = (cycle + phase).truncatingRemainder(dividingBy: 1.0)
                    let scale = (0.42 + (phasedCycle * 2.0)) * tightened
                    let opacity = (1.0 - phasedCycle) * pulseMaxOpacity * (1.0 - (phase * 0.28))

                    Circle()
                        .stroke(signalColor.opacity(opacity), lineWidth: 1.6)
                        .frame(width: 72, height: 72)
                        .scaleEffect(scale)
                        .offset(pulseBiasOffset)
                }
            }
        }
    }

    private var directionalBiasGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: signalColor.opacity(0.18 + signalIntensity * 0.12), location: 0.0),
                        .init(color: signalColor.opacity(0.05), location: 0.45),
                        .init(color: .clear, location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 6,
                    endRadius: 110
                )
            )
            .frame(width: 180, height: 180)
            .offset(pulseBiasOffset)
            .blendMode(.screen)
    }

    private var pulseDuration: TimeInterval {
        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            return 2.4
        }

        if rssi >= -45 { return 1.05 }
        if rssi >= -60 { return 1.35 }
        return 1.85
    }

    private var pulseMaxOpacity: Double {
        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            return 0.2
        }

        if rssi >= -45 { return 0.62 }
        if rssi >= -60 { return 0.46 }
        return 0.32
    }

    private var radarOffset: CGSize {
        if findState == .arrived {
            return .zero
        }
        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            // No direct signal — place dot at outer edge
            return CGSize(width: 60, height: -40)
        }

        let norm = max(0, min(1, Double(rssi + 90) / 50.0))
        let distance = 80.0 * (1.0 - norm)

        return CGSize(width: distance * 0.7, height: -distance * 0.5)
    }

    private var signalIntensity: Double {
        guard case .directSignalLocked(let rssi, _) = findSignalState else { return 0.2 }
        return max(0.2, min(1.0, Double(rssi + 90) / 45.0))
    }

    private var pulseBiasOffset: CGSize {
        CGSize(width: radarOffset.width * 0.15, height: radarOffset.height * 0.15)
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

            if findState == .arrived {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)

                Text("You found each other")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)

                Text("Look up — you’re close")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Text("Say hi 👋")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, 2)

                arrivedActions
            } else {
                switch findState {
                case .locked(let rssi):
                    let deviceId = bestPeerDevice?.id
                    let trend = deviceId.flatMap { rssiTrend(for: $0) } ?? 0

                    Text(proximityGradientLabel(rssi: rssi, trend: trend))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(signalColor)

                    Text(movementSuggestion(rssi: rssi, trend: trend))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    ambientGuidanceLine
                    conversationBridge(rssi: rssi)
                    fallbackActionSection

                case .searching:
                    switch findSignalState {
                    case .directSignalLocked(let rssi, let deviceId):
                    let trend = rssiTrend(for: deviceId) ?? 0

                    Text(proximityGradientLabel(rssi: rssi, trend: trend))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(signalColor)

                    Text(movementSuggestion(rssi: rssi, trend: trend))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    ambientGuidanceLine
                    conversationBridge(rssi: rssi)
                    fallbackActionSection

                    case .searchingForDirectSignal:
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.yellow)

                    Text(adaptiveSearchTitle(for: isBriefRecommendationMode ? "Connecting now" : "Signal suggests they may be nearby"))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.yellow)

                    Text(adaptiveSearchSubtitle(default: isBriefRecommendationMode ? "Walk naturally and look around — this is a good moment to approach." : "Move around naturally while Nearify keeps looking."))
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    ambientGuidanceLine
                    fallbackActionSection

                    case .fallbackEventPresence:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundColor(.orange)

                    Text(adaptiveSearchTitle(for: isBriefRecommendationMode ? "They may be nearby" : "Using event presence"))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)

                    Text(adaptiveSearchSubtitle(default: isBriefRecommendationMode ? "You can start walking over now while we refine their direction." : "Signal suggests they may be nearby at this event — walk naturally and look around."))
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    ambientGuidanceLine
                    fallbackActionSection

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

                    ambientGuidanceLine
                    fallbackActionSection
                    }
                case .arrived:
                    EmptyView()
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

    private func proximityGradientLabel(rssi: Int, trend: Int) -> String {
        if rssi >= -48 { return "Very close" }
        if rssi >= -63 || trend > 2 { return "You’re getting closer" }
        return "Signal is faint"
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

    private var ambientGuidanceLine: some View {
        Text(currentAmbientMessage)
            .id(currentAmbientMessage)
            .font(.caption)
            .foregroundColor(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.7), value: currentAmbientMessage)
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

    private var fallbackActionSection: some View {
        VStack(spacing: 10) {
            Text("Can’t find them?")
                .font(.caption.weight(.semibold))
                .foregroundColor(hasEnteredExtendedSearchState ? .white.opacity(0.9) : .gray.opacity(0.75))

            HStack(spacing: 10) {
                Button("See others nearby") {
                    dismiss()
                }
                .buttonStyle(fallbackButtonStyle(prominent: hasEnteredExtendedSearchState))

                Button("Back to event") {
                    dismiss()
                }
                .buttonStyle(fallbackButtonStyle(prominent: hasEnteredExtendedSearchState))
            }

            Button(isSearchExpanded ? "Search expanded" : "Expand search") {
                isSearchExpanded = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(isSearchExpanded ? .green.opacity(0.9) : .cyan.opacity(0.9))
            .padding(.top, 2)
            .disabled(isSearchExpanded)
        }
        .padding(.top, 4)
        .padding(.horizontal, 6)
    }

    private func fallbackButtonStyle(prominent: Bool) -> some ButtonStyle {
        CapsuleActionButtonStyle(
            backgroundColor: prominent ? Color.white.opacity(0.14) : Color.white.opacity(0.05),
            textColor: .white
        )
    }

    private func adaptiveSearchTitle(for base: String) -> String {
        hasEnteredExtendedSearchState ? "Still searching…" : base
    }

    private func adaptiveSearchSubtitle(default base: String) -> String {
        if hasEnteredExtendedSearchState {
            return "Try moving around or explore other connections"
        }
        if isSearchExpanded {
            return "Expanded search is on — we’ll include a wider nearby signal range."
        }
        return base
    }

    // MARK: - Signal Details

    private var signalDetailsView: some View {
        VStack(spacing: 6) {
            if findState == .arrived {
                Text("Arrival locked\(arrivedRSSI.map { " (\($0) dBm)" } ?? "") — signal updates paused")
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
                    Text("Signal suggests they may be active at this event")
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

    private var presenceCueText: String {
        if findState == .arrived {
            return "Look up — you’re close"
        }
        switch findSignalState {
        case .directSignalLocked(_, let deviceId):
            let trend = rssiTrend(for: deviceId) ?? 0
            if abs(trend) >= 5 { return "Moving around the room" }
            if abs(trend) >= 2 { return "Signal fluctuating" }
            return "Recently active nearby"
        case .searchingForDirectSignal:
            return "Recently active nearby"
        case .fallbackEventPresence:
            return "Signal suggests proximity"
        case .signalLost:
            return "Recently active nearby"
        }
    }

    private var isGettingCloserMoment: Bool {
        guard case .directSignalLocked(let rssi, let deviceId) = findSignalState else { return false }
        let trend = rssiTrend(for: deviceId) ?? 0
        return trend > 2 || rssi >= -52
    }

    private var currentAmbientMessage: String {
        if findState == .arrived {
            return "You found each other"
        }
        let messages: [String]
        switch findSignalState {
        case .directSignalLocked(let rssi, _):
            if rssi >= -48 {
                messages = ["You’re getting closer", "Pause and look around", "They may be nearby"]
            } else {
                messages = ["Try turning slightly", "Move a bit closer", "Signal is shifting…", "Pause and look around"]
            }
        case .searchingForDirectSignal:
            messages = ["Pause and look around", "Try turning slightly", "Signal is shifting…"]
        case .fallbackEventPresence:
            messages = ["They may be nearby", "Move a bit closer", "Pause and look around"]
        case .signalLost:
            messages = ["Signal is shifting…", "Try turning slightly", "They may be nearby"]
        }
        return messages[ambientMessageIndex % messages.count]
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

    private func startAmbientMessageRotation() {
        stopAmbientMessageRotation()
        ambientMessageTask = Task { @MainActor in
            while !Task.isCancelled {
                let waitSeconds = Double.random(in: 4.0 ... 6.0)
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                withAnimation(.easeInOut(duration: 0.7)) {
                    ambientMessageIndex += 1
                }
            }
        }
    }

    private func stopAmbientMessageRotation() {
        ambientMessageTask?.cancel()
        ambientMessageTask = nil
    }

    private let arrivalRSSIThreshold = -45
    private let arrivalStabilityDuration: TimeInterval = 2

    private func updateFindState() {
        let now = Date()
        if findState == .arrived {
            return
        }

        guard case .directSignalLocked(let rssi, _) = findSignalState else {
            findState = .searching
            proximityLockStartedAt = nil
            return
        }

        findState = .locked(rssi: rssi)
        guard rssi >= arrivalRSSIThreshold else {
            proximityLockStartedAt = nil
            return
        }

        if proximityLockStartedAt == nil {
            proximityLockStartedAt = now
            return
        }

        guard let lockStartedAt = proximityLockStartedAt else { return }
        guard now.timeIntervalSince(lockStartedAt) >= arrivalStabilityDuration else { return }
        enterArrivedState(rssi: rssi)
    }

    private func updateAdaptiveSearchState() {
        guard findState != .arrived else {
            hasEnteredExtendedSearchState = false
            return
        }

        guard case .directSignalLocked = findSignalState else {
            guard let startedAt = viewAppearedAt else { return }
            if Date().timeIntervalSince(startedAt) >= 24 {
                withAnimation(.easeInOut(duration: 0.25)) {
                    hasEnteredExtendedSearchState = true
                }
            }
            return
        }

        hasEnteredExtendedSearchState = false
    }

    private func enterArrivedState(rssi: Int) {
        findState = .arrived
        arrivedRSSI = rssi
        hasSavedConnection = ConnectionPromptStateStore.shared.isSaved(profileId: attendee.id, eventId: currentEventId)
        stopSignalTimer()
        stopAmbientMessageRotation()
        if !hasTriggeredArrivedHaptic {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            hasTriggeredArrivedHaptic = true
        }
        print("[FindAttendee] ARRIVED → stopping seek loop")
        print("[FindAttendee] ARRIVED state reached for \(attendee.name) (RSSI: \(rssi))")
        refreshConnectionStatusIfNeeded()
    }

    private var currentEventId: String? {
        EventJoinService.shared.currentEventID
    }

    private var attendeeContactDraft: ContactDraftData {
        ContactDraftData(
            name: attendee.name,
            eventName: EventJoinService.shared.currentEventName ?? "Nearify event",
            interests: attendee.interests ?? [],
            skills: attendee.skills ?? [],
            earnedTraits: []
        )
    }

    @ViewBuilder
    private var arrivedActions: some View {
        if shouldShowConnectAction {
            Button {
                saveConnection()
            } label: {
                HStack(spacing: 6) {
                    if isSavingConnection {
                        ProgressView().tint(.black)
                    }
                    Text("Connect")
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
            .padding(.horizontal, 16)
            .padding(.top, 4)
        } else if isAlreadyConnected {
            Text("You're already connected in Nearify")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.green.opacity(0.9))
                .padding(.top, 4)
        }

        Button {
            showContactSaveSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.plus")
                Text("Save to Contacts")
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.orange)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)

        HStack(spacing: 10) {
            Button("Back") { dismiss() }
                .buttonStyle(fallbackButtonStyle(prominent: true))
            Button("Keep exploring") { resetArrivedStateForExploration() }
                .buttonStyle(fallbackButtonStyle(prominent: true))
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private func saveConnection() {
        guard !isSavingConnection else { return }
        isSavingConnection = true

        Task {
            do {
                let result = try await ConnectionService.shared.createConnectionIfNeeded(to: attendee.id.uuidString)
                await MainActor.run {
                    switch result {
                    case .created:
                        hasSavedConnection = true
                        ConnectionPromptStateStore.shared.markSaved(profileId: attendee.id, eventId: currentEventId)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            transientConfirmationMessage = "Saved — find them later in People"
                        }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    case .alreadyExists:
                        isAlreadyConnected = true
                    }
                }

                if case .created = result {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            transientConfirmationMessage = nil
                        }
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

    private var shouldShowConnectAction: Bool {
        findState == .arrived && !hasSavedConnection && !isAlreadyConnected && !isCheckingConnectionStatus
    }

    private func resetArrivedStateForExploration() {
        findState = .searching
        proximityLockStartedAt = nil
        arrivedRSSI = nil
        hasTriggeredArrivedHaptic = false
        startSignalTimer()
        startAmbientMessageRotation()
    }

    private func refreshConnectionStatusIfNeeded() {
        guard !hasSavedConnection else {
            isAlreadyConnected = false
            return
        }

        guard !isCheckingConnectionStatus else { return }
        isCheckingConnectionStatus = true

        Task {
            let connected = await ConnectionService.shared.isConnected(with: attendee.id)
            await MainActor.run {
                isAlreadyConnected = connected
                if findState == .arrived {
                    print("[FindAttendee] arrived connected=\(connected)")
                }
                isCheckingConnectionStatus = false
            }
        }
    }
}

private struct CapsuleActionButtonStyle: ButtonStyle {
    let backgroundColor: Color
    let textColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundColor(textColor.opacity(configuration.isPressed ? 0.7 : 1))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Capsule().fill(backgroundColor.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}
