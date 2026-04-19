import SwiftUI

struct EventModeView: View {
    @StateObject private var bleService = BLEService.shared
    @ObservedObject private var state = EventModeState.shared
    @ObservedObject private var scanner = BLEScannerService.shared
    @ObservedObject private var advertiser = BLEAdvertiserService.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var attendees = EventAttendeesService.shared
    @ObservedObject private var resolver = AttendeeStateResolver.shared
    @ObservedObject private var confidence = BeaconConfidenceService.shared
    @ObservedObject private var presence = EventPresenceService.shared
    @ObservedObject private var beaconPresence = BeaconPresenceService.shared
    @State private var showingPrivacyInfo = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if !bleService.isScanning {
                        privacyNotice
                    }

                    eventModeToggle

                    if bleService.isScanning {
                        eventStatusCard
                        nearbyAttendeesCard
                        technicalDiagnostics
                    }

                    if let error = bleService.errorMessage {
                        errorCard(error)
                    }
                }
                .padding()
                .padding(.bottom, 20)
            }
            .navigationTitle("Event Mode")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPrivacyInfo) { privacySheet }
        }
    }

    // MARK: - Event Mode Toggle

    private var eventModeToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Event Mode")
                    .font(.title2).fontWeight(.bold)
                Text(bleService.isScanning ? "Active" : "Off")
                    .font(.subheadline)
                    .foregroundColor(bleService.isScanning ? .green : .secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { bleService.isScanning },
                set: { newValue in
                    Task {
                        if newValue { await bleService.startEventMode() }
                        else { bleService.stopEventMode() }
                    }
                }
            ))
            .labelsHidden()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }

    // MARK: - Event Status Card

    private var eventStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Canonical membership state banner
            HStack(spacing: 8) {
                Image(systemName: state.membership.iconName)
                    .foregroundColor(state.membership.displayColor)
                    .font(.system(size: 12))
                Text(state.membership.displayLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(state.membership.displayColor)
            }

            switch state.status {
            case .idle:
                EmptyView()

            case .scanningForEvent:
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundColor(.orange)
                    Text("Ready to Join")
                        .font(.headline)
                }
                Text("Scan an event QR code to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

            case .joinedLooking(let eventName):
                eventJoinedHeader(eventName)
                Text("Scanning for nearby attendees…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

            case .joinedWithNearby(let eventName, _):
                eventJoinedHeader(eventName)
                Text(state.attendeeSummaryText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(statusCardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(statusCardStroke, lineWidth: 1)
                )
        )
    }

    private func eventJoinedHeader(_ eventName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(eventName)
                .font(.headline)
            Spacer()
            NavigationLink(destination: NetworkView()) {
                Text("Network")
                    .font(.caption).fontWeight(.medium)
                    .foregroundColor(.blue)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.blue)
            }
        }
    }

    private var statusCardFill: Color {
        switch state.status {
        case .joinedLooking, .joinedWithNearby: return Color.green.opacity(0.08)
        default: return Color.orange.opacity(0.08)
        }
    }

    private var statusCardStroke: Color {
        switch state.status {
        case .joinedLooking, .joinedWithNearby: return Color.green.opacity(0.2)
        default: return Color.orange.opacity(0.2)
        }
    }

    // MARK: - Nearby Attendees Card

    private var nearbyAttendeesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(.blue)
                Text("Nearby Attendees")
                    .font(.headline)
                Spacer()
                if state.nearbyResolvedCount > 0 {
                    Text("\(state.nearbyResolvedCount)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue))
                }
            }

            let resolved = resolver.resolvedPeerDevices(attendees: attendees.attendees)
            if resolved.isEmpty {
                // Time-aware guidance instead of passive empty state
                if attendees.attendees.isEmpty {
                    Text("Move to discover people")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("Someone is nearby — go say hi")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
            } else {
                ForEach(resolved.prefix(5), id: \.device.id) { match in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text(match.attendee.name)
                            .font(.subheadline)
                        Spacer()
                        Text(match.device.signalStrength)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if resolved.count > 5 {
                    Text("+ \(resolved.count - 5) more")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }

    // MARK: - Technical Diagnostics (collapsed by default)

    private var technicalDiagnostics: some View {
        DisclosureGroup("Technical Diagnostics", isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 8) {
                diagRow("BLE Scanning", scanner.isScanning ? "Active" : "Off")
                diagRow("BLE Advertising", advertiser.isAdvertising ? "Active" : "Off")
                diagRow("Host Anchor Mode", advertiser.isHostAnchorMode ? "ON" : "Off")
                diagRow("BLE Peers", "\(state.blePeerCount)")
                diagRow("Resolved Nearby", "\(state.nearbyResolvedCount)")
                diagRow("Active Attendees", "\(state.activeAttendeeCount)")
                diagRow("Event Joined", eventJoin.isEventJoined ? "Yes" : "No")
                diagRow("Membership", state.membership.displayLabel)
                if let name = eventJoin.currentEventName {
                    diagRow("Event Name", name)
                }
                diagRow("Presence Status", presence.debugStatus)
                if let lastWrite = presence.lastPresenceWrite {
                    diagRow("Last Presence", lastWrite.formatted(date: .omitted, time: .standard))
                }

                // Host Anchor Mode toggle
                if eventJoin.isEventJoined {
                    Divider().padding(.vertical, 4)
                    HStack {
                        Text("Host Anchor Mode")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { advertiser.isHostAnchorMode },
                            set: { newValue in
                                if newValue {
                                    advertiser.enableHostAnchorMode()
                                } else {
                                    advertiser.disableHostAnchorMode()
                                }
                            }
                        ))
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    Text("Broadcasts this phone as the event anchor")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Anchor detection (all sources)
                Divider().padding(.vertical, 4)
                Text("Anchor Detection")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                diagRow("Confidence State", confidence.confidenceState.displayText)
                if let beacon = confidence.activeBeacon {
                    diagRow("Anchor Name", beacon.name)
                    diagRow("Anchor RSSI", "\(beacon.rssi) dBm")
                }

                // Beacon Presence (environmental confidence layer)
                Divider().padding(.vertical, 4)
                Text("Beacon Presence (environmental)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                diagRow("Zone State", beaconPresence.currentZoneState.rawValue)
                diagRow("Beacon Visible", beaconPresence.isBeaconVisible ? "Yes" : "No")
                diagRow("Confidence", String(format: "%.0f%%", beaconPresence.beaconConfidence * 100))
                diagRow("Anchor Source", beaconPresence.anchorSource)
                if let lastSeen = beaconPresence.lastBeaconSeenAt {
                    diagRow("Last Seen", lastSeen.formatted(date: .omitted, time: .standard))
                }
                diagRow("Beacon Reinforced", presence.isBeaconReinforced ? "Yes" : "No")
            }
            .padding(.top, 8)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    // MARK: - Error Card

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.red)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Privacy Notice

    private var privacyNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your privacy matters")
                    .font(.subheadline).fontWeight(.medium)
                Text("Event Mode uses Bluetooth to discover nearby attendees. Your data stays on your device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { showingPrivacyInfo = true }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))
    }

    // MARK: - Privacy Sheet

    private var privacySheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    privacySection(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Bluetooth Discovery",
                        text: "Event Mode uses Bluetooth Low Energy (BLE) to discover other attendees nearby. Your device broadcasts a short anonymous identifier that other Nearify users can detect."
                    )
                    privacySection(
                        icon: "eye.slash",
                        title: "What We Share",
                        text: "Only a short prefix of your community ID is broadcast. Your name, photo, and profile details are never sent over Bluetooth."
                    )
                    privacySection(
                        icon: "person.2",
                        title: "Proximity to Other Attendees",
                        text: "Your proximity to other attendees is estimated using Bluetooth signal strength. This information is used only to show who is nearby and is not stored or shared."
                    )
                    privacySection(
                        icon: "hand.raised",
                        title: "Your Control",
                        text: "You can turn off Event Mode at any time to stop broadcasting and scanning. No data is collected when Event Mode is off."
                    )
                }
                .padding()
            }
            .navigationTitle("Privacy Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showingPrivacyInfo = false }
                }
            }
        }
    }

    private func privacySection(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline).fontWeight(.semibold)
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    EventModeView()
}
