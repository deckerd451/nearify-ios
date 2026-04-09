import SwiftUI

struct NetworkView: View {
    @ObservedObject private var attendees = EventAttendeesService.shared
    @ObservedObject private var presence = EventPresenceService.shared
    @ObservedObject private var scanner = BLEScannerService.shared
    @ObservedObject private var stateResolver = AttendeeStateResolver.shared
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var intelligence = EventIntelligenceService.shared
    @ObservedObject private var modeState = EventModeState.shared

    @State private var showMockAttendees = false
    @State private var showSettings = false
    @State private var showPresenceTestResult = false
    @State private var selectedAttendee: EventAttendee?
    @State private var viewMode: ViewMode = .visualization
    @State private var showLeaveConfirmation = false

    enum ViewMode { case visualization, list }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                switch modeState.membership {
                case .notInEvent: inactiveState
                case .inEvent, .inactive: activeEventView
                case .left, .timedOut: exitedState
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if modeState.membership.isParticipating, !displayAttendees.isEmpty {
                        Picker("View", selection: $viewMode) {
                            Image(systemName: "circle.grid.2x2").tag(ViewMode.visualization)
                            Image(systemName: "list.bullet").tag(ViewMode.list)
                        }.pickerStyle(.segmented).frame(width: 100)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: "gearshape").foregroundColor(.white)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .sheet(item: $selectedAttendee) { a in FindAttendeeView(attendee: a) }
            .confirmationDialog("Leave Event", isPresented: $showLeaveConfirmation, titleVisibility: .visible) {
                Button("Leave Event", role: .destructive) { Task { await eventJoin.leaveEvent() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your connections and messages will be kept. You can rejoin by scanning the QR code again.") }
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    stateResolver.refreshConnections(); attendees.refresh(); intelligence.refresh()
                }
            }
        }
    }
    private var stateBanner: some View {
        let s = modeState.membership
        return HStack(spacing: 8) {
            Image(systemName: s.iconName).foregroundColor(s.displayColor).font(.system(size: 12))
            Text(s.displayLabel).font(.caption).fontWeight(.medium).foregroundColor(s.displayColor)
        }.padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(s.displayColor.opacity(0.15)))
    }
    private var inactiveState: some View {
        ScrollView { VStack(spacing: 24) { VStack(spacing: 12) {
            Image(systemName: "person.3").font(.system(size: 48)).foregroundColor(.gray)
            Text("No Active Event").font(.title2).fontWeight(.semibold).foregroundColor(.white)
            Text("Join an event to see nearby attendees").font(.subheadline).foregroundColor(.gray)
            Text("Your connections and messages are always available in the Feed.").font(.caption).foregroundColor(.gray.opacity(0.6)).multilineTextAlignment(.center).padding(.horizontal, 32)
        }.padding(.top, 32) } }
    }
    private var exitedState: some View {
        ScrollView { VStack(spacing: 24) { VStack(spacing: 16) {
            stateBanner
            if let n = modeState.membership.eventName { Text(n).font(.headline).foregroundColor(.white.opacity(0.6)) }
            exitExplanationText
            Button { eventJoin.acknowledgeExit() } label: {
                Text("OK").font(.subheadline).fontWeight(.medium).foregroundColor(.white).padding(.horizontal, 32).padding(.vertical, 10).background(Capsule().fill(Color.white.opacity(0.15)))
            }
        }.padding(.top, 32) } }
    }
    @ViewBuilder private var exitExplanationText: some View {
        switch modeState.membership {
        case .left: VStack(spacing: 6) {
            Text("You left this event.").font(.subheadline).foregroundColor(.gray)
            Text("Your connections and messages are still available in the Feed.").font(.caption).foregroundColor(.gray.opacity(0.7)).multilineTextAlignment(.center)
            Text("Scan the QR code again to rejoin.").font(.caption).foregroundColor(.gray.opacity(0.5))
        }
        case .timedOut: VStack(spacing: 6) {
            Text("You were removed due to inactivity.").font(.subheadline).foregroundColor(.gray)
            Text("Your connections and messages are still available in the Feed.").font(.caption).foregroundColor(.gray.opacity(0.7)).multilineTextAlignment(.center)
            Text("Scan the QR code again to rejoin.").font(.caption).foregroundColor(.gray.opacity(0.5))
        }
        default: EmptyView()
        }
    }
    private var activeEventView: some View {
        ScrollView { VStack(spacing: 0) {
            eventHeader; topPeopleSection; nearbyDevicesSection
            if displayAttendees.isEmpty { emptyState }
            else { if viewMode == .visualization { attendeeVisualization.frame(height: 420) } else { attendeeListView.padding(.horizontal) } }
        } }
    }
    private var eventHeader: some View {
        VStack(spacing: 8) {
            if let en = eventJoin.currentEventName ?? presence.currentEvent {
                Text(en).font(.headline).foregroundColor(.white)
                HStack(spacing: 4) { Circle().fill(Color.green).frame(width: 6, height: 6); Text("Live at this event").font(.caption2).foregroundColor(.green.opacity(0.8)) }
            }
            stateBanner
            HStack(spacing: 16) {
                Label("\(displayAttendees.count) attendees", systemImage: "person.2.fill").font(.caption).foregroundColor(.gray)
                if attendees.isLoading { ProgressView().scaleEffect(0.6).tint(.gray) }
            }
            if case .inEvent = modeState.membership {
                Button { showLeaveConfirmation = true } label: {
                    HStack(spacing: 4) { Image(systemName: "arrow.right.circle").font(.system(size: 12)); Text("Leave Event").font(.caption).fontWeight(.medium) }
                    .foregroundColor(.red.opacity(0.8)).padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 1))
                }.padding(.top, 4)
            }
        }.padding().background(Color.black.opacity(0.3))
    }
    private var topPeopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "sparkles").foregroundColor(.yellow); Text("Top People Right Now").font(.headline).foregroundColor(.white); Spacer(); if intelligence.isLoading { ProgressView().scaleEffect(0.6).tint(.gray) } }
            if intelligence.topPeople.isEmpty {
                VStack(spacing: 6) { HStack(spacing: 8) { Image(systemName: "figure.walk").foregroundColor(.gray); Text("No strong interactions right now").font(.caption).foregroundColor(.gray) }; Text("Move around to discover people nearby").font(.caption2).foregroundColor(.gray.opacity(0.6)) }.padding(.vertical, 4)
            } else { VStack(spacing: 8) { ForEach(intelligence.topPeople) { p in topPersonRow(p) } } }
        }.padding().background(Color.white.opacity(0.03)).cornerRadius(16).padding(.horizontal).padding(.top, 12)
    }
    private func topPersonRow(_ person: RankedProfile) -> some View {
        let d = person.decision; let ins = person.insight
        let ac: Color = { if let t = d?.tier { switch t { case .activeConversation: return .blue; case .strongInteraction: return .green; case .breakthroughPotential: return .cyan; case .repeatedNearMiss: return .orange; case .followUpGap: return .purple; case .fallback: return .gray } }; switch ins?.needState { case .belonging: return .orange; case .esteem: return .purple; case .selfActualization: return .cyan; case .none: return .blue } }()
        return HStack(spacing: 10) {
            Circle().fill(person.isConnected ? Color.green.opacity(0.2) : ac.opacity(0.2)).frame(width: 36, height: 36)
                .overlay(Text(String(person.name.prefix(2)).uppercased()).font(.caption2).fontWeight(.bold).foregroundColor(person.isConnected ? .green : ac))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { Text(person.name).font(.subheadline).fontWeight(.medium).foregroundColor(.white); if person.isConnected { Image(systemName: "link").font(.system(size: 9)).foregroundColor(.green) }; if person.hasMessaged { Image(systemName: "bubble.left.fill").font(.system(size: 9)).foregroundColor(.blue) } }
                if let r = d?.reason { Text(r).font(.caption2).foregroundColor(ac.opacity(0.9)).lineLimit(2) } else if let it = ins?.insightText { Text(it).font(.caption2).foregroundColor(ac.opacity(0.9)).lineLimit(2) } else if person.encounterStrength > 0 { let m = person.encounterStrength / 60; Text(m > 0 ? "\(m)m nearby" : "\(person.encounterStrength)s nearby").font(.caption2).foregroundColor(.orange) }
                if let t = d?.tier { Text(t.label).font(.system(size: 9, weight: .semibold)).foregroundColor(.black).padding(.horizontal, 6).padding(.vertical, 2).background(ac.opacity(0.8)).cornerRadius(4) }
            }; Spacer()
            NavigationLink(destination: FeedProfileDetailView(profileId: person.profileId)) { Image(systemName: "chevron.right").font(.caption).foregroundColor(.gray) }
        }.padding(10).background(Color.white.opacity(0.04)).cornerRadius(10)
    }
    private var nearbyDevicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Proximity Signals").font(.headline).foregroundColor(.white); Spacer(); Text("\(nearbyDevices.count)").font(.caption).foregroundColor(.gray) }
            if nearbyDevices.isEmpty { Text("No nearby signals detected").font(.subheadline).foregroundColor(.gray) }
            else { VStack(spacing: 10) { ForEach(nearbyDevices) { dev in nearbyDeviceRow(dev) } } }
        }.padding().background(Color.white.opacity(0.03)).cornerRadius(16).padding(.horizontal).padding(.top, 12)
    }
    private func nearbyDeviceRow(_ device: DiscoveredBLEDevice) -> some View {
        let rn = resolvedAttendeeName(for: device)
        return HStack(spacing: 10) {
            Circle().fill(deviceColor(for: device)).frame(width: 10, height: 10).flexibleFrame(minWidth: 10, maxWidth: 10)
            Text(rn ?? device.name).font(.subheadline).foregroundColor(rn != nil ? .cyan : .white).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if device.name.hasPrefix("BCN-") { deviceTag("ATTENDEE", color: .cyan) } else if device.name.contains("MOONSIDE") || device.isKnownBeacon { deviceTag("ANCHOR", color: .blue) }
            Spacer(minLength: 4); Text("\(device.rssi) dBm").font(.caption2).foregroundColor(.gray).fixedSize()
        }.padding(10).background(Color.white.opacity(0.04)).cornerRadius(12)
    }
    private func deviceTag(_ text: String, color: Color) -> some View { Text(text).font(.system(size: 9, weight: .bold)).foregroundColor(.black).padding(.horizontal, 5).padding(.vertical, 2).background(color).cornerRadius(4).fixedSize() }
    private var emptyState: some View {
        VStack(spacing: 20) { Spacer(minLength: 32); Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 60)).foregroundColor(.gray); Text("You're the first one here").font(.title3).fontWeight(.semibold).foregroundColor(.white); Text("\(attendees.attendeeCount) attendees in this event.\nOthers will appear as they join.").font(.subheadline).foregroundColor(.gray).multilineTextAlignment(.center).padding(.horizontal, 40); Spacer(minLength: 32) }.frame(maxWidth: .infinity)
    }
    private var attendeeVisualization: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ps = displayAttendees.map { stateResolver.resolve(for: $0) }
            ZStack {
                ForEach(Array(ps.enumerated()), id: \.element.attendee.id) { i, p in
                    let r = radiusForAttendee(p.attendee, in: geo.size); let pos = radialPosition(index: i, total: ps.count, center: c, radius: r)
                    Path { path in path.move(to: c); path.addLine(to: pos) }.stroke(p.edgeColor, lineWidth: p.edgeWidth)
                }
                Circle().fill(Color.blue).frame(width: 50, height: 50).overlay(Text("You").font(.caption).fontWeight(.bold).foregroundColor(.white)).position(c)
                ForEach(Array(ps.enumerated()), id: \.element.attendee.id) { i, p in
                    let r = radiusForAttendee(p.attendee, in: geo.size); let pos = radialPosition(index: i, total: ps.count, center: c, radius: r); let sz = nodeSize(for: p.attendee)
                    graphNode(pres: p, size: sz).position(pos).onTapGesture { selectedAttendee = p.attendee }
                }
            }
        }.padding(.top, 20).animation(.easeInOut(duration: 0.35), value: displayAttendees.map { proximityScore(for: $0) })
    }
    private func graphNode(pres: AttendeePresentation, size: CGFloat) -> some View {
        VStack(spacing: 3) {
            ZStack {
                if pres.hasRing { Circle().stroke(pres.ringColor, lineWidth: 2).frame(width: size + 6, height: size + 6) }
                Circle().fill(pres.nodeColor).frame(width: size, height: size).overlay(Text(pres.attendee.initials).font(.caption).fontWeight(.bold).foregroundColor(.white)).opacity(pres.nodeOpacity)
                if pres.relationship == .connected { Image(systemName: "link").font(.system(size: 8, weight: .bold)).foregroundColor(.black).padding(3).background(Circle().fill(pres.ringColor)).offset(x: size / 2 - 2, y: -(size / 2 - 2)) }
            }
            Text(pres.attendee.name).font(.caption2).fontWeight(.semibold).foregroundColor(.white.opacity(pres.nodeOpacity)).lineLimit(1).frame(maxWidth: 80)
            Text(pres.attendee.graphSubtitleText).font(.system(size: 9)).foregroundColor(.white.opacity(0.6 * pres.nodeOpacity)).lineLimit(1).frame(maxWidth: 80)
        }
    }
    private var attendeeListView: some View {
        LazyVStack(spacing: 12) { ForEach(displayAttendees) { a in Button(action: { selectedAttendee = a }) { AttendeeCardView(attendee: a) }.buttonStyle(.plain) } }.padding(.vertical, 16)
    }
    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Event Info")) {
                    HStack { Text("Event"); Spacer(); Text(eventJoin.currentEventName ?? presence.currentEvent ?? "None").foregroundColor(.secondary) }
                    HStack { Text("State"); Spacer(); Text(modeState.membership.displayLabel).foregroundColor(.secondary) }
                    HStack { Text("Nearby Attendees"); Spacer(); Text("\(attendees.attendeeCount)").foregroundColor(.secondary) }
                    HStack { Text("Proximity Signals"); Spacer(); Text("\(nearbyDevices.count)").foregroundColor(.secondary) }
                }
                Section(header: Text("Diagnostics")) {
                    Toggle("Show Mock Attendees", isOn: $showMockAttendees)
                    Button(action: { Task { await EventPresenceService.shared.debugWritePresenceNow(); await MainActor.run { showPresenceTestResult = true } } }) { HStack { Image(systemName: "arrow.up.doc.fill"); Text("Test Presence Write"); Spacer() } }
                    .alert("Presence Test Result", isPresented: $showPresenceTestResult) { Button("OK", role: .cancel) {} } message: { Text(presence.debugStatus) }
                }
            }.navigationTitle("Event Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { showSettings = false } } }
        }
    }
    private var displayAttendees: [EventAttendee] { showMockAttendees ? mockAttendees : attendees.attendees }
    private func proximityScore(for a: EventAttendee) -> Double { guard let d = stateResolver.peerDevice(for: a) else { return 0.5 }; let r = scanner.smoothedRSSI(for: d.id) ?? d.rssi; switch r { case -45...0: return 1.0; case -55..<(-45): return 0.8; case -65..<(-55): return 0.6; case -75..<(-65): return 0.4; default: return 0.25 } }
    private func radiusForAttendee(_ a: EventAttendee, in s: CGSize) -> CGFloat { let mn = min(s.width, s.height) * 0.18; let mx = min(s.width, s.height) * 0.36; return mx - (mx - mn) * CGFloat(proximityScore(for: a)) }
    private func nodeSize(for a: EventAttendee) -> CGFloat { 38 + 14 * CGFloat(proximityScore(for: a)) }
    private func radialPosition(index: Int, total: Int, center: CGPoint, radius: CGFloat) -> CGPoint { guard total > 0 else { return center }; let a = (Double(index) / Double(total)) * 2.0 * .pi; return CGPoint(x: center.x + CGFloat(cos(a)) * radius, y: center.y + CGFloat(sin(a)) * radius) }
    private var nearbyDevices: [DiscoveredBLEDevice] { scanner.getFilteredDevices().filter { $0.isKnownBeacon || $0.name.hasPrefix("BEACON-") || $0.name.hasPrefix("BCN-") }.sorted { $0.rssi > $1.rssi } }
    private func deviceColor(for d: DiscoveredBLEDevice) -> Color { if d.name.hasPrefix("BCN-") { return .cyan }; if d.name.hasPrefix("BEACON-") { return .green }; if d.isKnownBeacon { return .orange }; return .gray }
    private func resolvedAttendeeName(for d: DiscoveredBLEDevice) -> String? { guard let p = BLEAdvertiserService.parseCommunityPrefix(from: d.name) else { return nil }; return displayAttendees.first { String($0.id.uuidString.prefix(8)).lowercased() == p }?.name }
    private var mockAttendees: [EventAttendee] { [
        EventAttendee(id: UUID(), name: "Alice Johnson", avatarUrl: nil, bio: nil, skills: [], interests: [], energy: 0.8, lastSeen: Date().addingTimeInterval(-10)),
        EventAttendee(id: UUID(), name: "Bob Smith", avatarUrl: nil, bio: nil, skills: [], interests: [], energy: 0.6, lastSeen: Date().addingTimeInterval(-45)),
        EventAttendee(id: UUID(), name: "Carol Davis", avatarUrl: nil, bio: nil, skills: [], interests: [], energy: 0.4, lastSeen: Date().addingTimeInterval(-120)),
    ] }
}
private extension View { func flexibleFrame(minWidth: CGFloat, maxWidth: CGFloat) -> some View { self.frame(minWidth: minWidth, maxWidth: maxWidth) } }
