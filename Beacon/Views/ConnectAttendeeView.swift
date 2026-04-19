import SwiftUI
import AVFoundation

/// Connection handshake screen: direct connect (primary) + QR fallback.
struct ConnectAttendeeView: View {
    let attendee: EventAttendee
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authService = AuthService.shared

    @State private var connectionState: ConnectionState = .ready
    @State private var scannerKey = UUID()
    @State private var cameraAccessDenied = false
    @State private var showQRFallback = false

    enum ConnectionState: Equatable {
        case ready
        case connecting
        case success(alreadyExisted: Bool)
        case savedLocally
        case error(String)
    }

    /// Whether the view is operating in Nearby Mode (offline).
    private var isNearbyMode: Bool {
        AuthService.shared.isOfflineMode || !NetworkMonitor.shared.isOnline
    }

    private var myQRImage: UIImage? {
        guard let user = authService.currentUser else { return nil }
        return QRService.generateQRCode(for: user.id.uuidString)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if case .success(let existed) = connectionState {
                    successView(alreadyExisted: existed)
                } else if case .savedLocally = connectionState {
                    savedLocallyView
                } else {
                    handshakeView
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Handshake View

    private var handshakeView: some View {
        ScrollView {
            VStack(spacing: 20) {
                identityHeader
                directConnectButton

                if case .error(let msg) = connectionState {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 24)
                }

                if showQRFallback {
                    qrFallbackSection
                } else {
                    Button(action: { withAnimation { showQRFallback = true } }) {
                        Label("Use QR code instead", systemImage: "qrcode")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private var identityHeader: some View {
        VStack(spacing: 6) {
            AvatarView(
                imageUrl: attendee.avatarUrl,
                name: attendee.name,
                size: 56
            )

            Text(attendee.name)
                .font(.headline)
                .foregroundColor(.white)

            if isNearbyMode {
                Text(isAlreadyConfirmed ? "Met nearby ✓" : "Detected nearby · Bluetooth")
                    .font(.caption)
                    .foregroundColor(.cyan)
            } else {
                Text("Verified attendee · Very close")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Direct Connect

    /// Whether this attendee has already been confirmed in Nearby Mode.
    private var isAlreadyConfirmed: Bool {
        let prefix = String(attendee.id.uuidString.prefix(8)).lowercased()
        return NearbyModeTracker.shared.isConfirmed(prefix: prefix)
    }

    private var directConnectButton: some View {
        Group {
            if isNearbyMode && isAlreadyConfirmed {
                // Already confirmed — show static saved state
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Met nearby ✓")
                        .fontWeight(.semibold)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.cyan.opacity(0.2))
                .foregroundColor(.cyan)
                .cornerRadius(14)
                .padding(.horizontal, 24)
            } else {
                Button(action: { handleDirectConnect() }) {
                    HStack(spacing: 10) {
                        if case .connecting = connectionState {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: isNearbyMode ? "checkmark.circle" : "person.crop.circle.badge.plus")
                        }
                        Text(isNearbyMode ? "Save encounter" : "Connect with \(attendee.name)")
                            .fontWeight(.semibold)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(connectionState == .connecting
                                ? (isNearbyMode ? Color.cyan.opacity(0.5) : Color.green.opacity(0.5))
                                : (isNearbyMode ? Color.cyan : Color.green))
                    .foregroundColor(.black)
                    .cornerRadius(14)
                }
                .disabled(connectionState == .connecting)
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - QR Fallback

    private var qrFallbackSection: some View {
        VStack(spacing: 16) {
            HStack {
                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                Text("OR USE QR")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 8)
                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            }
            .padding(.horizontal, 32)

            // Your QR
            VStack(spacing: 8) {
                Text("Let them scan your code")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .textCase(.uppercase)

                if let qr = myQRImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 160, height: 160)
                        .background(Color.white)
                        .cornerRadius(12)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 160, height: 160)
                        .overlay(ProgressView().tint(.white))
                }
            }

            HStack {
                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                Text("OR")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 8)
                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            }
            .padding(.horizontal, 32)

            // Scanner
            VStack(spacing: 8) {
                Text("Scan their QR code")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .textCase(.uppercase)

                if cameraAccessDenied {
                    cameraAccessView
                } else {
                    ZStack {
                        CameraPreview(
                            onCodeScanned: { code in handleScan(code) },
                            onPermissionDenied: { cameraAccessDenied = true }
                        )
                        .id(scannerKey)
                        .frame(height: 200)
                        .cornerRadius(12)
                        .clipped()

                        if case .connecting = connectionState {
                            Color.black.opacity(0.6).cornerRadius(12)
                            ProgressView().tint(.white).scaleEffect(1.5)
                        }
                    }
                    .frame(height: 200)
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    private var cameraAccessView: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundColor(.gray)
            Text("Camera access needed")
                .font(.caption)
                .foregroundColor(.gray)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.caption)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    // MARK: - Success View

    private func successView(alreadyExisted: Bool) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: alreadyExisted ? "checkmark.seal.fill" : "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text(alreadyExisted ? "Already Connected" : "Connected")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text(alreadyExisted
                 ? "You and \(attendee.name) are already connected"
                 : "You and \(attendee.name) are now connected")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.black)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Saved Locally View (Nearby Mode)

    private var savedLocallyView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.cyan)

            Text("Encounter Saved")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Met \(attendee.name) nearby — will sync when online")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.cyan)
                    .foregroundColor(.black)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Direct Connect Handler

    private func handleDirectConnect() {
        guard connectionState == .ready || {
            if case .error = connectionState { return true }
            return false
        }() else { return }

        print("[Connect] 🤝 Direct connect tapped for \(attendee.name) (id: \(attendee.id))")

        // Nearby Mode: save encounter locally instead of calling backend
        if isNearbyMode {
            handleNearbyModeConnect()
            return
        }

        connectionState = .connecting

        Task {
            do {
                let result = try await ConnectionService.shared.createConnectionIfNeeded(
                    to: attendee.id.uuidString
                )
                await MainActor.run {
                    switch result {
                    case .created:
                        connectionState = .success(alreadyExisted: false)
                        print("[Connect] ✅ Connection created with \(attendee.name)")
                    case .alreadyExists:
                        connectionState = .success(alreadyExisted: true)
                        print("[Connect] ℹ️ Already connected with \(attendee.name)")
                    }
                    AttendeeStateResolver.shared.refreshConnections()

                    // Fire-and-forget: ingest QR-confirmed interaction into interaction_events
                    let currentUser = AuthService.shared.currentUser
                    let eventIdString = EventJoinService.shared.currentEventID

                    print("[QR-Direct] ── Ingestion gate check ──")
                    print("[QR-Direct]   currentUser          = \(currentUser?.id.uuidString ?? "NIL")")
                    print("[QR-Direct]   currentUser.userId   = \(currentUser?.userId?.uuidString ?? "NIL") (auth ID — NOT used)")
                    print("[QR-Direct]   eventIdString         = \(eventIdString ?? "NIL")")
                    print("[QR-Direct]   attendee.id (target)  = \(attendee.id)")

                    if let currentUser = currentUser,
                       let eventIdString = eventIdString,
                       let eventId = UUID(uuidString: eventIdString) {
                        print("[QR-Direct] ✅ All values present — calling ingestion")
                        print("[QR-Direct]   eventId       = \(eventId)")
                        print("[QR-Direct]   fromProfileId = \(currentUser.id) (profiles.id)")
                        print("[QR-Direct]   toProfileId   = \(attendee.id) (profiles.id)")
                        NearifyIngestionService.shared.ingestQRConfirmedInteraction(
                            eventId: eventId,
                            fromProfileId: currentUser.id,
                            toProfileId: attendee.id
                        )
                    } else {
                        print("[QR-Direct] ❌ SKIP ingestion — missing values:")
                        if currentUser == nil { print("[QR-Direct]   REASON: currentUser is nil") }
                        if eventIdString == nil { print("[QR-Direct]   REASON: currentEventID is nil — user may not have joined an event") }
                        if let s = eventIdString, UUID(uuidString: s) == nil { print("[QR-Direct]   REASON: currentEventID '\(s)' is not a valid UUID") }
                    }
                }
            } catch {
                await MainActor.run {
                    connectionState = .error("Connection failed. Try again.")
                    print("[Connect] ❌ Direct connect error: \(error)")
                }
            }
        }
    }

    // MARK: - Nearby Mode Connect (local save)

    private func handleNearbyModeConnect() {
        let prefix = String(attendee.id.uuidString.prefix(8)).lowercased()

        // Prevent duplicate confirmation
        if NearbyModeTracker.shared.isConfirmed(prefix: prefix) {
            connectionState = .savedLocally
            #if DEBUG
            print("[NearbyMode] already confirmed: \(attendee.name) (prefix: \(prefix))")
            #endif
            return
        }

        // Build a local encounter from the attendee data
        let encounter = NearbyModeTracker.LocalEncounter(
            id: prefix,
            profileId: attendee.id,
            name: attendee.name,
            avatarUrl: attendee.avatarUrl,
            firstSeen: attendee.lastSeen,
            lastSeen: Date(),
            strongestRSSI: -50,
            latestRSSI: -50
        )

        NearbyModeTracker.shared.confirmEncounter(encounter)
        connectionState = .savedLocally

        #if DEBUG
        print("[NearbyMode] local encounter confirmed: \(attendee.name) (prefix: \(prefix))")
        print("[NearbyMode] saved locally")
        #endif
    }

    // MARK: - QR Scan Handler

    private func handleScan(_ code: String) {
        guard connectionState == .ready || {
            if case .error = connectionState { return true }
            return false
        }() else { return }

        print("[Connect] 📷 QR fallback scanned: \(code)")

        guard let payload = QRService.parse(from: code),
              case .profile(let scannedId) = payload else {
            connectionState = .error("Not a valid profile QR code")
            resetScanner()
            return
        }

        connectionState = .connecting

        Task {
            do {
                let result = try await ConnectionService.shared.createConnectionIfNeeded(to: scannedId)
                await MainActor.run {
                    switch result {
                    case .created:
                        connectionState = .success(alreadyExisted: false)
                        print("[Connect] ✅ QR connection created with \(scannedId)")
                    case .alreadyExists:
                        connectionState = .success(alreadyExisted: true)
                        print("[Connect] ℹ️ QR: already connected with \(scannedId)")
                    }
                    AttendeeStateResolver.shared.refreshConnections()

                    // Fire-and-forget: ingest QR-confirmed interaction into interaction_events
                    let currentUser = AuthService.shared.currentUser
                    let toCommunityId = UUID(uuidString: scannedId)
                    let eventIdString = EventJoinService.shared.currentEventID

                    print("[QR-Scan] ── Ingestion gate check ──")
                    print("[QR-Scan]   currentUser          = \(currentUser?.id.uuidString ?? "NIL")")
                    print("[QR-Scan]   currentUser.userId   = \(currentUser?.userId?.uuidString ?? "NIL") (auth ID — NOT used)")
                    print("[QR-Scan]   eventIdString         = \(eventIdString ?? "NIL")")
                    print("[QR-Scan]   scannedId (raw)       = \(scannedId)")
                    print("[QR-Scan]   toCommunityId (UUID?) = \(toCommunityId?.uuidString ?? "NIL")")

                    if let currentUser = currentUser,
                       let toCommunityId = toCommunityId,
                       let eventIdString = eventIdString,
                       let eventId = UUID(uuidString: eventIdString) {
                        print("[QR-Scan] ✅ All values present — calling ingestion")
                        print("[QR-Scan]   eventId       = \(eventId)")
                        print("[QR-Scan]   fromProfileId = \(currentUser.id) (profiles.id)")
                        print("[QR-Scan]   toProfileId   = \(toCommunityId) (profiles.id)")
                        NearifyIngestionService.shared.ingestQRConfirmedInteraction(
                            eventId: eventId,
                            fromProfileId: currentUser.id,
                            toProfileId: toCommunityId
                        )
                    } else {
                        print("[QR-Scan] ❌ SKIP ingestion — missing values:")
                        if currentUser == nil { print("[QR-Scan]   REASON: currentUser is nil") }
                        if toCommunityId == nil { print("[QR-Scan]   REASON: scannedId '\(scannedId)' failed UUID parse") }
                        if eventIdString == nil { print("[QR-Scan]   REASON: currentEventID is nil — user may not have joined an event") }
                        if let s = eventIdString, UUID(uuidString: s) == nil { print("[QR-Scan]   REASON: currentEventID '\(s)' is not a valid UUID") }
                    }
                }
            } catch {
                await MainActor.run {
                    connectionState = .error("Connection failed. Try again.")
                    resetScanner()
                    print("[Connect] ❌ QR connection error: \(error)")
                }
            }
        }
    }

    private func resetScanner() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if case .error = connectionState {
                connectionState = .ready
            }
            scannerKey = UUID()
        }
    }
}
