import SwiftUI

/// Admin-only Intelligence Debug panel.
/// Explains how the system interprets real-world interactions.
/// Access: long-press Profile tab (debug builds) or AppEnvironment.isDebugMode.
struct IntelligenceDebugView: View {
    @ObservedObject private var eventJoin = EventJoinService.shared
    @ObservedObject private var presence = EventPresenceService.shared
    @ObservedObject private var scanner = BLEScannerService.shared
    @ObservedObject private var state = EventModeState.shared
    @ObservedObject private var dynamicProfile = DynamicProfileService.shared
    @ObservedObject private var encounters = EncounterService.shared
    @ObservedObject private var beaconPresence = BeaconPresenceService.shared
    @ObservedObject private var beaconConfidence = BeaconConfidenceService.shared

    @State private var debugSummary: DynamicProfileService.DebugProfileSummary?
    @State private var isLoadingSummary = false

    // MARK: - Action Feedback State

    @State private var actionInFlight: DebugAction?
    @State private var lastActionName: String?
    @State private var lastActionTimestamp: Date?
    @State private var lastActionResult: String?

    /// Which section just updated — drives highlight animation.
    @State private var highlightedSection: DebugSection?

    private enum DebugAction: String {
        case presenceWrite = "Test Presence Write"
        case refreshSignals = "Force Refresh Signals"
        case refreshFeed = "Force Refresh Feed"
    }

    private enum DebugSection {
        case presenceHealth
        case signalLayer
        case intelligenceOutput
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                presenceHealthSection
                peerBLESection
                anchorBeaconSection
                behaviorTendenciesSection
                signalLayerSection
                intelligenceOutputSection
                debugActionsSection
                lastActionSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Intelligence Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadSummary() }
        }
    }

    // MARK: - 1. Presence Health

    private var presenceHealthSection: some View {
        Section("Presence Health") {
            debugRow("Event Name", eventJoin.currentEventName ?? "None")
            debugRow("Joined", eventJoin.isEventJoined ? "Yes" : "No")
            debugRow("Membership", state.membership.displayLabel)
            debugRow("Home State", HomeStateResolver.shared.state.rawValue)
            debugRow("Profile ID", AuthService.shared.currentUser?.id.uuidString.prefix(8).description ?? "—")
            debugRow("Heartbeat", presence.isWritingPresence ? "Active" : "Stale")
            debugRow("Beacon Reinforced", presence.isBeaconReinforced ? "Yes" : "No")
            debugRow("Presence Status", presence.debugStatus)
            if let lastWrite = presence.lastPresenceWrite {
                debugRow("Last Seen", lastWrite.formatted(date: .omitted, time: .standard))
            }
        }
        .listRowBackground(
            highlightedSection == .presenceHealth
                ? Color.green.opacity(0.08) : nil
        )
    }

    // MARK: - Peer BLE (other attendees' phones)

    private var peerBLESection: some View {
        Section("Peer BLE (attendee phones)") {
            debugRow("BLE Scanning", scanner.isScanning ? "On" : "Off")
            debugRow("BCN Peers", "\(state.blePeerCount)")
            debugRow("Resolved Nearby", "\(state.nearbyResolvedCount)")
            debugRow("Active Attendees", "\(state.activeAttendeeCount)")
            debugRow("Nearby Peer Count", "\(beaconConfidence.nearbyPeerCount)")
        }
    }

    // MARK: - Anchor Beacon (physical event beacon / zone signal)

    private var anchorBeaconSection: some View {
        Section("Anchor Beacon (event zone signal)") {
            debugRow("Zone State", beaconPresence.currentZoneState.rawValue)
            debugRow("Beacon Visible", beaconPresence.isBeaconVisible ? "Yes" : "No")
            debugRow("Beacon Confidence", String(format: "%.0f%%", beaconPresence.beaconConfidence * 100))
            debugRow("Anchor Source", beaconPresence.anchorSource)
            if let lastSeen = beaconPresence.lastBeaconSeenAt {
                debugRow("Beacon Last Seen", lastSeen.formatted(date: .omitted, time: .standard))
            } else {
                debugRow("Beacon Last Seen", "Never")
            }
            debugRow("Confidence State", beaconConfidence.confidenceState.displayText)
            if let anchor = beaconConfidence.activeBeacon {
                debugRow("Anchor Name", anchor.name)
                debugRow("Anchor RSSI", "\(anchor.rssi) dBm")
            }
        }
    }

    // MARK: - Behavior Tendencies

    private var behaviorTendenciesSection: some View {
        Section("Behavior Tendencies") {
            let tendencies = BehaviorProfileService.shared.tendencies
            if tendencies.isEmpty {
                Text("No behavior data yet").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(tendencies) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(t.id)
                                    .font(.caption).fontWeight(.semibold)
                                Text(t.isConfident ? "ACTIVE" : "BELOW THRESHOLD")
                                    .font(.caption2)
                                    .foregroundColor(t.isConfident ? .green : .gray)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background((t.isConfident ? Color.green : Color.gray).opacity(0.12))
                                    .cornerRadius(4)
                            }
                            Text("\(t.confidence) / \(t.minConfidence) observations")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - 2. Signal Layer

    private var signalLayerSection: some View {
        Section("Signal Layer") {
            if let summary = debugSummary {
                let s = summary.signals

                if let top = summary.topProximityInteraction {
                    debugRow("Top Proximity", top)
                } else {
                    debugRow("Top Proximity", "None")
                }

                debugRow("Encounters (recent)", "\(s.encounterCount)")
                debugRow("Messages", s.messageCount > 0 ? "Yes (\(s.messageCount))" : "No")
                debugRow("Connections", "\(s.connectionCount)")
                debugRow("Conn→Msg Follow-up", "\(s.connectionsFollowedByMessages)")
                debugRow("Distinct Events", "\(s.distinctEventCount)")

                if let dom = s.dominantEvent {
                    debugRow("Dominant Event", "\(dom) ×\(s.dominantEventHits)")
                }

                debugRow("Theme Clusters", "\(s.distinctClusterCount)")

                if let top = s.topConnectorTheme {
                    debugRow("Top Connector Theme", "\(top) (\(s.topConnectorThemePeople) people)")
                }

                if let top = s.topTheme {
                    debugRow("Top Theme", "\(top) (\(s.topThemeInteractions) interactions)")
                }

                if !s.activeThemes.isEmpty {
                    debugRow("Active Themes", s.activeThemes.joined(separator: ", "))
                }
            } else if isLoadingSummary {
                HStack {
                    ProgressView()
                    Text("Loading signals…").font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text("No signal data").font(.caption).foregroundColor(.secondary)
            }
        }
        .listRowBackground(
            highlightedSection == .signalLayer
                ? Color.blue.opacity(0.08) : nil
        )
    }

    // MARK: - 3. Intelligence Output

    private var intelligenceOutputSection: some View {
        Section("Intelligence Output") {
            // Lately
            VStack(alignment: .leading, spacing: 4) {
                Text("Lately")
                    .font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
                if dynamicProfile.latelyLines.isEmpty {
                    Text("(none)").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(dynamicProfile.latelyLines, id: \.self) { line in
                        Text("• \(line)").font(.caption)
                    }
                }
            }
            .padding(.vertical, 2)

            // Emerging Strengths
            VStack(alignment: .leading, spacing: 4) {
                Text("Emerging Strengths")
                    .font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
                if let paragraph = dynamicProfile.emergingStrengthsParagraph {
                    Text(paragraph).font(.caption)
                } else {
                    Text("(none — below threshold)").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)

            // Earned Traits
            VStack(alignment: .leading, spacing: 4) {
                Text("Earned Traits")
                    .font(.caption2).foregroundColor(.secondary).textCase(.uppercase)
                if dynamicProfile.earnedTraits.isEmpty {
                    Text("(none — thresholds not met)").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(dynamicProfile.earnedTraits) { trait in
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2).foregroundColor(.green)
                            Text(trait.publicText).font(.caption)
                            Text("(\(trait.evidenceCount) evidence)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 2)

            // Trait Evidence (earned traits debug)
            if let summary = debugSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trait Evidence")
                        .font(.caption2).foregroundColor(.secondary).textCase(.uppercase)

                    ForEach(summary.traitEvidence, id: \.traitKey) { ev in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: ev.qualified ? "checkmark.seal.fill" : "xmark.circle")
                                    .font(.caption2)
                                    .foregroundColor(ev.qualified ? .green : .gray)
                                Text(ev.traitName)
                                    .font(.caption).fontWeight(.semibold)
                                Text(ev.qualified ? "QUALIFIED" : "NOT MET")
                                    .font(.caption2)
                                    .foregroundColor(ev.qualified ? .green : .gray)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background((ev.qualified ? Color.green : Color.gray).opacity(0.12))
                                    .cornerRadius(4)
                            }

                            ForEach(ev.metrics, id: \.label) { m in
                                HStack(spacing: 4) {
                                    Image(systemName: m.met ? "checkmark" : "xmark")
                                        .font(.system(size: 8))
                                        .foregroundColor(m.met ? .green : .red)
                                    Text("\(m.label): \(m.actual) / \(m.required)")
                                        .font(.caption2)
                                        .foregroundColor(m.met ? .primary : .secondary)
                                }
                            }

                            if let text = ev.outputText {
                                Text("→ \(text)")
                                    .font(.caption2)
                                    .foregroundColor(.green.opacity(0.8))
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 2)
            }

            // Trait evaluations (the WHY)
            if let summary = debugSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trait Evaluations")
                        .font(.caption2).foregroundColor(.secondary).textCase(.uppercase)

                    ForEach(summary.traitEvaluations, id: \.family) { eval in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(eval.family)
                                    .font(.caption).fontWeight(.semibold)
                                Text(tierBadge(eval.tier))
                                    .font(.caption2)
                                    .foregroundColor(tierColor(eval.tier))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(tierColor(eval.tier).opacity(0.12))
                                    .cornerRadius(4)
                            }
                            if let phrase = eval.phrase {
                                Text(phrase)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            Text(eval.reason)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listRowBackground(
            highlightedSection == .intelligenceOutput
                ? Color.purple.opacity(0.08) : nil
        )
    }

    // MARK: - 4. Debug Actions

    private var debugActionsSection: some View {
        Section("Debug Actions") {
            actionButton(.presenceWrite) {
                let statusBefore = presence.debugStatus
                let lastWriteBefore = presence.lastPresenceWrite

                await presence.debugWritePresenceNow()

                // Brief pause to let @Published propagate
                try? await Task.sleep(nanoseconds: 300_000_000)

                let statusAfter = presence.debugStatus
                let lastWriteAfter = presence.lastPresenceWrite
                let changed = statusAfter != statusBefore || lastWriteAfter != lastWriteBefore

                flashSection(.presenceHealth)

                if statusAfter.contains("FAILED") {
                    return "Failed — \(statusAfter)"
                } else if changed {
                    return "Heartbeat updated — \(statusAfter)"
                } else {
                    return "Triggered — no change detected"
                }
            }

            actionButton(.refreshSignals) {
                let linesBefore = dynamicProfile.latelyLines
                let paragraphBefore = dynamicProfile.emergingStrengthsParagraph

                dynamicProfile.refresh()
                // Wait for the async refresh to complete
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                await loadSummary()

                let linesAfter = dynamicProfile.latelyLines
                let paragraphAfter = dynamicProfile.emergingStrengthsParagraph
                let changed = linesAfter != linesBefore || paragraphAfter != paragraphBefore

                flashSection(.intelligenceOutput)

                if changed {
                    let parts = [
                        linesAfter != linesBefore ? "Lately updated" : nil,
                        paragraphAfter != paragraphBefore ? "Strengths updated" : nil
                    ].compactMap { $0 }
                    return "Refreshed — \(parts.joined(separator: ", "))"
                } else {
                    return "Refreshed — no changes detected"
                }
            }

            actionButton(.refreshFeed) {
                let countBefore = FeedService.shared.feedItems.count
                let summaryBefore = debugSummary

                FeedService.shared.requestRefresh(reason: "debug-panel")
                // Wait for feed refresh to complete
                try? await Task.sleep(nanoseconds: 2_500_000_000)

                await loadSummary()

                let countAfter = FeedService.shared.feedItems.count
                let signalsChanged = didSignalsChange(before: summaryBefore, after: debugSummary)

                flashSection(.signalLayer)

                if countAfter != countBefore || signalsChanged {
                    var parts: [String] = []
                    if countAfter != countBefore {
                        parts.append("feed \(countBefore)→\(countAfter) items")
                    }
                    if signalsChanged {
                        parts.append("signals updated")
                    }
                    return "Refreshed — \(parts.joined(separator: ", "))"
                } else {
                    return "Refreshed — same output (\(countAfter) items)"
                }
            }
        }
    }

    // MARK: - 5. Last Action Status

    private var lastActionSection: some View {
        Section("Last Action") {
            if let name = lastActionName, let timestamp = lastActionTimestamp {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: resultIcon(lastActionResult))
                            .font(.caption)
                            .foregroundColor(resultColor(lastActionResult))
                        Text(name)
                            .font(.caption).fontWeight(.semibold)
                    }
                    Text(timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundColor(.secondary)
                    if let result = lastActionResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(resultColor(result))
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("No actions performed yet")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Action Button Builder

    /// Builds a button with spinner, disabled-while-in-flight, and result capture.
    private func actionButton(
        _ action: DebugAction,
        perform work: @escaping () async -> String
    ) -> some View {
        Button {
            guard actionInFlight == nil else { return }
            actionInFlight = action

            Task {
                let result = await work()

                await MainActor.run {
                    lastActionName = action.rawValue
                    lastActionTimestamp = Date()
                    lastActionResult = result
                    actionInFlight = nil
                }
            }
        } label: {
            HStack(spacing: 8) {
                if actionInFlight == action {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(action.rawValue)
                    .foregroundColor(actionInFlight == action ? .secondary : .accentColor)
                Spacer()
                if actionInFlight == action {
                    Text("Running…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .disabled(actionInFlight != nil)
    }

    // MARK: - Helpers

    private func loadSummary() async {
        isLoadingSummary = true
        debugSummary = await dynamicProfile.debugSummary()
        isLoadingSummary = false
    }

    /// Briefly highlights a section, then clears after a short delay.
    private func flashSection(_ section: DebugSection) {
        withAnimation(.easeIn(duration: 0.15)) {
            highlightedSection = section
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.4)) {
                if highlightedSection == section {
                    highlightedSection = nil
                }
            }
        }
    }

    /// Compares two debug summaries to detect signal-level changes.
    private func didSignalsChange(
        before: DynamicProfileService.DebugProfileSummary?,
        after: DynamicProfileService.DebugProfileSummary?
    ) -> Bool {
        guard let b = before?.signals, let a = after?.signals else { return true }
        return b.messageCount != a.messageCount
            || b.connectionCount != a.connectionCount
            || b.encounterCount != a.encounterCount
            || b.distinctEventCount != a.distinctEventCount
            || b.distinctClusterCount != a.distinctClusterCount
            || b.topTheme != a.topTheme
            || b.topThemeInteractions != a.topThemeInteractions
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
    }

    private func tierBadge(_ tier: String) -> String {
        switch tier {
        case "high": return "HIGH"
        case "medium": return "MED"
        case "low": return "LOW"
        default: return "NONE"
        }
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier {
        case "high": return .green
        case "medium": return .orange
        case "low": return .yellow
        default: return .gray
        }
    }

    private func resultIcon(_ result: String?) -> String {
        guard let r = result else { return "circle" }
        if r.contains("Failed") { return "xmark.circle.fill" }
        if r.contains("no change") || r.contains("same output") { return "equal.circle.fill" }
        return "checkmark.circle.fill"
    }

    private func resultColor(_ result: String?) -> Color {
        guard let r = result else { return .secondary }
        if r.contains("Failed") { return .red }
        if r.contains("no change") || r.contains("same output") { return .secondary }
        return .green
    }
}
