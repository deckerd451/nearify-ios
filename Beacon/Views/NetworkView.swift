import SwiftUI

struct NetworkView: View {
    @ObservedObject private var attendees = EventAttendeesService.shared
    @ObservedObject private var presence = EventPresenceService.shared
    @ObservedObject private var scanner = BLEScannerService.shared
    @ObservedObject private var stateResolver = AttendeeStateResolver.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var intelligence = EventIntelligenceService.shared

    @State private var showMockAttendees = false
    @State private var showSettings = false
    @State private var showPresenceTestResult = false
    @State private var selectedAttendee: EventAttendee?
    @State private var viewMode: ViewMode = .visualization

    enum ViewMode {
        case visualization
        case list
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if presence.currentEvent == nil && !eventJoin.isEventJoined {
                    inactiveState
                } else {
                    activeEventView
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if (presence.currentEvent != nil || eventJoin.isEventJoined) && !displayAttendees.isEmpty {
                        Picker("View Mode", selection: $viewMode) {
                            Image(systemName: "circle.grid.2x2").tag(ViewMode.visualization)
                            Image(systemName: "list.bullet").tag(ViewMode.list)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: "gearshape")
                            .foregroundColor(.white)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .sheet(item: $selectedAttendee) { attendee in
                FindAttendeeView(attendee: attendee)
            }
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    stateResolver.refreshConnections()
                    attendees.refresh()
                    intelligence.refresh()
                }
            }
        }
    }

    // MARK: - Inactive State

    private var inactiveState: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "person.3")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)

                    Text("No Active Event")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text("Join an event to see nearby attendees")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.top, 32)
            }
        }
    }

    // MARK: - Active Event View

    private var activeEventView: some View {
        ScrollView {
            VStack(spacing: 0) {
                eventHeader

                // 1. Top People Right Now — intelligence layer
                topPeopleSection

                // 2. Proximity Signals — raw nearby data
                nearbyDevicesSection

                // 3. Attendee Graph — spatial visualization
                if displayAttendees.isEmpty {
                    emptyState
                } else {
                    if viewMode == .visualization {
                        attendeeVisualization
                            .frame(height: 420)
                    } else {
                        attendeeListView
                            .padding(.horizontal)
                    }
                }
            }
        }
    }

    private var eventHeader: some View {
        VStack(spacing: 8) {
            if let eventName = eventJoin.currentEventName ?? presence.currentEvent {
                Text(eventName)
                    .font(.headline)
                    .foregroundColor(.white)
            }

            if eventJoin.isEventJoined {
                Text("Event active · Proximity enabled")
                    .font(.caption)
                    .foregroundColor(.green)
            } else if presence.currentEvent != nil {
                Text("Event detected")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack(spacing: 16) {
                Label("\(displayAttendees.count) attendees", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundColor(.gray)

                if attendees.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.gray)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
    }

    // MARK: - Top People Right Now

    private var topPeopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.yellow)
                Text("Top People Right Now")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                if intelligence.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.gray)
                }
            }

            if intelligence.topPeople.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "figure.walk")
                        .foregroundColor(.gray)
                    Text("Move around and meet people to unlock suggestions")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(intelligence.topPeople) { person in
                        topPersonRow(person)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private func topPersonRow(_ person: RankedProfile) -> some View {
        HStack(spacing: 10) {
            // Avatar with need-state color
            let needColor: Color = {
                switch person.insight?.needState {
                case .belonging: return .orange
                case .esteem: return .purple
                case .selfActualization: return .cyan
                case .none: return .blue
                }
            }()

            Circle()
                .fill(person.isConnected ? Color.green.opacity(0.2) : needColor.opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(String(person.name.prefix(2)).uppercased())
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(person.isConnected ? .green : needColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(person.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)

                    if person.isConnected {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                    }
                    if person.hasMessaged {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.blue)
                    }
                }

                // Show insight text instead of raw score
                if let insight = person.insight {
                    Text(insight.insightText)
                        .font(.caption2)
                        .foregroundColor(needColor.opacity(0.9))
                        .lineLimit(2)
                } else {
                    HStack(spacing: 6) {
                        if person.encounterStrength > 0 {
                            let mins = person.encounterStrength / 60
                            Text(mins > 0 ? "\(mins)m nearby" : "\(person.encounterStrength)s nearby")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Spacer()

            NavigationLink(destination: FeedProfileDetailView(profileId: person.profileId)) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Nearby Devices

    private var nearbyDevicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Proximity Signals")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text("\(nearbyDevices.count)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if nearbyDevices.isEmpty {
                Text("No nearby signals detected")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            } else {
                VStack(spacing: 10) {
                    ForEach(nearbyDevices) { device in
                        nearbyDeviceRow(device)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private func nearbyDeviceRow(_ device: DiscoveredBLEDevice) -> some View {
        let resolvedName = resolvedAttendeeName(for: device)

        return HStack(spacing: 10) {
            Circle()
                .fill(deviceColor(for: device))
                .frame(width: 10, height: 10)
                .flexibleFrame(minWidth: 10, maxWidth: 10)

            Text(resolvedName ?? device.name)
                .font(.subheadline)
                .foregroundColor(resolvedName != nil ? .cyan : .white)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if device.name.hasPrefix("BCN-") {
                deviceTag("ATTENDEE", color: .cyan)
            } else if device.name.contains("MOONSIDE") || device.isKnownBeacon {
                deviceTag("ANCHOR", color: .blue)
            }

            Spacer(minLength: 4)

            Text("\(device.rssi) dBm")
                .font(.caption2)
                .foregroundColor(.gray)
                .fixedSize()
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func deviceTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
            .fixedSize()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 32)
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("You're the first one here")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            Text("\(attendees.attendeeCount) attendees in this event.\nOthers will appear as they join.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Graph Visualization

    private var attendeeVisualization: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let presentations = displayAttendees.map { stateResolver.resolve(for: $0) }

            ZStack {
                ForEach(Array(presentations.enumerated()), id: \.element.attendee.id) { index, pres in
                    let radius = radiusForAttendee(pres.attendee, in: geo.size)
                    let position = radialPosition(index: index, total: presentations.count, center: center, radius: radius)
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: position)
                    }
                    .stroke(pres.edgeColor, lineWidth: pres.edgeWidth)
                }

                Circle()
                    .fill(Color.blue)
                    .frame(width: 50, height: 50)
                    .overlay(Text("You").font(.caption).fontWeight(.bold).foregroundColor(.white))
                    .position(center)

                ForEach(Array(presentations.enumerated()), id: \.element.attendee.id) { index, pres in
                    let radius = radiusForAttendee(pres.attendee, in: geo.size)
                    let position = radialPosition(index: index, total: presentations.count, center: center, radius: radius)
                    let size = nodeSize(for: pres.attendee)
                    graphNode(pres: pres, size: size)
                        .position(position)
                        .onTapGesture { selectedAttendee = pres.attendee }
                }
            }
        }
        .padding(.top, 20)
        .animation(.easeInOut(duration: 0.35), value: displayAttendees.map { proximityScore(for: $0) })
    }

    private func graphNode(pres: AttendeePresentation, size: CGFloat) -> some View {
        VStack(spacing: 3) {
            ZStack {
                if pres.hasRing {
                    Circle().stroke(pres.ringColor, lineWidth: 2).frame(width: size + 6, height: size + 6)
                }
                Circle().fill(pres.nodeColor).frame(width: size, height: size)
                    .overlay(Text(pres.attendee.initials).font(.caption).fontWeight(.bold).foregroundColor(.white))
                    .opacity(pres.nodeOpacity)
                if pres.relationship == .connected {
                    Image(systemName: "link").font(.system(size: 8, weight: .bold)).foregroundColor(.black)
                        .padding(3).background(Circle().fill(pres.ringColor))
                        .offset(x: size / 2 - 2, y: -(size / 2 - 2))
                }
            }
            Text(pres.attendee.name).font(.caption2).fontWeight(.semibold)
                .foregroundColor(.white.opacity(pres.nodeOpacity)).lineLimit(1).frame(maxWidth: 80)
            Text(pres.attendee.graphSubtitleText).font(.system(size: 9))
                .foregroundColor(.white.opacity(0.6 * pres.nodeOpacity)).lineLimit(1).frame(maxWidth: 80)
        }
    }

    // MARK: - Attendee List View

    private var attendeeListView: some View {
        LazyVStack(spacing: 12) {
            ForEach(displayAttendees) { attendee in
                Button(action: { selectedAttendee = attendee }) {
                    AttendeeCardView(attendee: attendee)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Event Info")) {
                    HStack {
                        Text("Event"); Spacer()
                        Text(eventJoin.currentEventName ?? presence.currentEvent ?? "None").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Nearby Attendees"); Spacer()
                        Text("\(attendees.attendeeCount)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Proximity Signals"); Spacer()
                        Text("\(nearbyDevices.count)").foregroundColor(.secondary)
                    }
                }
                Section(header: Text("Diagnostics")) {
                    Toggle("Show Mock Attendees", isOn: $showMockAttendees)
                    Button(action: {
                        Task {
                            await EventPresenceService.shared.debugWritePresenceNow()
                            await MainActor.run { showPresenceTestResult = true }
                        }
                    }) {
                        HStack { Image(systemName: "arrow.up.doc.fill"); Text("Test Presence Write"); Spacer() }
                    }
                    .alert("Presence Test Result", isPresented: $showPresenceTestResult) {
                        Button("OK", role: .cancel) {}
                    } message: { Text(presence.debugStatus) }
                }
            }
            .navigationTitle("Event Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private var displayAttendees: [EventAttendee] {
        showMockAttendees ? mockAttendees : attendees.attendees
    }

    private func proximityScore(for attendee: EventAttendee) -> Double {
        guard let device = stateResolver.peerDevice(for: attendee) else { return 0.5 }
        let rssi = scanner.smoothedRSSI(for: device.id) ?? device.rssi
        switch rssi {
        case -45...0: return 1.0
        case -55..<(-45): return 0.8
        case -65..<(-55): return 0.6
        case -75..<(-65): return 0.4
        default: return 0.25
        }
    }

    private func radiusForAttendee(_ attendee: EventAttendee, in size: CGSize) -> CGFloat {
        let minR = min(size.width, size.height) * 0.18
        let maxR = min(size.width, size.height) * 0.36
        return maxR - (maxR - minR) * CGFloat(proximityScore(for: attendee))
    }

    private func nodeSize(for attendee: EventAttendee) -> CGFloat {
        38 + (52 - 38) * CGFloat(proximityScore(for: attendee))
    }

    private func radialPosition(index: Int, total: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        guard total > 0 else { return center }
        let angle = (Double(index) / Double(total)) * 2.0 * .pi
        return CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
    }

    private var nearbyDevices: [DiscoveredBLEDevice] {
        scanner.getFilteredDevices()
            .filter { $0.isKnownBeacon || $0.name.hasPrefix("BEACON-") || $0.name.hasPrefix("BCN-") }
            .sorted { $0.rssi > $1.rssi }
    }

    private func deviceColor(for device: DiscoveredBLEDevice) -> Color {
        if device.name.hasPrefix("BCN-") { return .cyan }
        if device.name.hasPrefix("BEACON-") { return .green }
        if device.isKnownBeacon { return .orange }
        return .gray
    }

    private func resolvedAttendeeName(for device: DiscoveredBLEDevice) -> String? {
        guard let prefix = BLEAdvertiserService.parseCommunityPrefix(from: device.name) else { return nil }
        return displayAttendees.first { String($0.id.uuidString.prefix(8)).lowercased() == prefix }?.name
    }

    private var mockAttendees: [EventAttendee] {
        [
            EventAttendee(id: UUID(), name: "Alice Johnson", avatarUrl: nil, bio: nil, skills: [], interests: [], energy: 0.8, lastSeen: Date().addingTimeInterval(-10)),
            EventAttendee(id: UUID(), name: "Bob Smith", avatarUrl: nil, bio: nil, skills: [], interests: [], energy: 0.6, lastSeen: Date().addingTimeInterval(-45)),
            EventAttendee(id: UUID(), name: "Carol Davis", avatarUrl: nil, bio: nil, skills: [], interests: [], energy: 0.4, lastSeen: Date().addingTimeInterval(-120)),
        ]
    }
}

private extension View {
    func flexibleFrame(minWidth: CGFloat, maxWidth: CGFloat) -> some View {
        self.frame(minWidth: minWidth, maxWidth: maxWidth)
    }
}
