import SwiftUI

/// People Nearby section for Nearby Mode.
/// Shows BLE-detected peers with signal strength, cached identity, and gated actions.
/// Confirmed encounters show "Met nearby ✓" badge and prevent duplicate actions.
struct NearbyPeopleSectionView: View {
    @ObservedObject private var tracker = NearbyModeTracker.shared
    @ObservedObject private var scanner = BLEScannerService.shared

    let onFind: (NearbyModeTracker.LocalEncounter) -> Void

    var body: some View {
        let active = tracker.activeEncounters
        let recent = tracker.recentEncounters
        let confirmed = tracker.confirmedEncounters

        VStack(alignment: .leading, spacing: 16) {
            // MARK: - People Nearby (active BLE)
            if !active.isEmpty {
                sectionHeader("People Nearby", count: active.count)

                ForEach(active) { encounter in
                    nearbyPersonCard(encounter, isActive: true)
                }
            }

            // MARK: - Seen Nearby (recent + confirmed, no longer in BLE range)
            let seenList = mergedSeenList(recent: recent, confirmed: confirmed)
            if !seenList.isEmpty {
                sectionHeader("Seen Nearby", count: seenList.count)

                ForEach(seenList) { item in
                    seenNearbyCard(item)
                }
            }

            // MARK: - Empty State
            if active.isEmpty && seenList.isEmpty {
                emptyState
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Text("\(count)")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.4))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
    }

    // MARK: - Active Person Card

    private func nearbyPersonCard(_ encounter: NearbyModeTracker.LocalEncounter, isActive: Bool) -> some View {
        let isConfirmed = tracker.isConfirmed(prefix: encounter.id)

        return HStack(spacing: 12) {
            avatarView(name: encounter.name, avatarUrl: encounter.avatarUrl)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(encounter.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)

                    if isConfirmed {
                        metBadge
                    }
                }

                HStack(spacing: 6) {
                    // Signal strength
                    Image(systemName: signalIcon(encounter.latestRSSI))
                        .font(.system(size: 9))
                        .foregroundColor(signalColor(encounter.latestRSSI))

                    Text(isConfirmed ? "Nearby · Met nearby ✓" : encounter.signalLabel)
                        .font(.caption2)
                        .foregroundColor(isConfirmed ? .cyan : signalColor(encounter.latestRSSI))

                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.2))

                    Text(encounter.lastSeenText)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer()

            // Action area
            if isConfirmed {
                // Already confirmed — show saved badge, no duplicate action
                Text("✓ Saved")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.cyan.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.1))
                    .cornerRadius(6)
            } else {
                Button {
                    onFind(encounter)
                } label: {
                    Text("Find")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.cyan)
                        .cornerRadius(8)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - Seen Nearby Card

    /// Unified model for the Seen Nearby section — merges recent BLE encounters
    /// with confirmed encounters that may no longer be in BLE range.
    struct SeenItem: Identifiable {
        let id: String
        let name: String
        let avatarUrl: String?
        let dwellText: String
        let lastSeenText: String
        let isConfirmed: Bool
        let syncStatus: NearbyModeTracker.PendingConfirmation.SyncStatus?
    }

    private func mergedSeenList(
        recent: [NearbyModeTracker.LocalEncounter],
        confirmed: [NearbyModeTracker.PendingConfirmation]
    ) -> [SeenItem] {
        var items: [SeenItem] = []
        var seenPrefixes = Set<String>()

        // Recent BLE encounters first
        for enc in recent {
            seenPrefixes.insert(enc.id)
            let confirmation = confirmed.first { $0.blePrefix == enc.id }
            items.append(SeenItem(
                id: enc.id,
                name: enc.name,
                avatarUrl: enc.avatarUrl,
                dwellText: enc.dwellText,
                lastSeenText: enc.lastSeenText,
                isConfirmed: confirmation != nil,
                syncStatus: confirmation?.syncStatus
            ))
        }

        // Confirmed encounters not in recent BLE list
        for conf in confirmed where !seenPrefixes.contains(conf.blePrefix) {
            seenPrefixes.insert(conf.blePrefix)
            let dwell = conf.dwellSeconds
            let dwellText = dwell < 60 ? "Just now" : "About \(dwell / 60) minutes"
            let age = Int(Date().timeIntervalSince(conf.timestamp))
            let lastSeenText: String
            if age < 60 { lastSeenText = "Seen just now" }
            else if age < 3600 { lastSeenText = "Seen \(age / 60) min ago" }
            else { lastSeenText = "Seen earlier" }

            items.append(SeenItem(
                id: conf.blePrefix,
                name: conf.remoteName,
                avatarUrl: nil,
                dwellText: dwellText,
                lastSeenText: lastSeenText,
                isConfirmed: true,
                syncStatus: conf.syncStatus
            ))
        }

        return Array(items.prefix(20))
    }

    private func seenNearbyCard(_ item: SeenItem) -> some View {
        HStack(spacing: 12) {
            avatarView(name: item.name, avatarUrl: item.avatarUrl)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.8))

                    if item.isConfirmed {
                        metBadge
                    }
                }

                HStack(spacing: 6) {
                    Text("Nearby for \(item.dwellText.lowercased())")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))

                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.2))

                    Text(item.lastSeenText)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer()

            // Status label
            if item.isConfirmed {
                VStack(spacing: 2) {
                    Text("✓ Saved")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.cyan.opacity(0.7))

                    if let status = item.syncStatus {
                        Text(syncLabel(status))
                            .font(.system(size: 8))
                            .foregroundColor(syncColor(status))
                    }
                }
            } else {
                Text("Out of range")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
        )
    }

    // MARK: - Met Badge

    private var metBadge: some View {
        Text("MET")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.cyan)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.cyan.opacity(0.15))
            .cornerRadius(3)
    }

    // MARK: - Sync Status Helpers

    private func syncLabel(_ status: NearbyModeTracker.PendingConfirmation.SyncStatus) -> String {
        switch status {
        case .pending: return "Will sync"
        case .synced:  return "Synced ✓"
        case .failed:  return "Sync pending"
        }
    }

    private func syncColor(_ status: NearbyModeTracker.PendingConfirmation.SyncStatus) -> Color {
        switch status {
        case .pending: return .orange.opacity(0.5)
        case .synced:  return .green.opacity(0.6)
        case .failed:  return .orange.opacity(0.5)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 40)

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 36))
                .foregroundColor(.cyan.opacity(0.3))

            Text("Nearby Mode is active")
                .font(.headline)
                .foregroundColor(.white.opacity(0.7))

            Text("We'll show people here as they come into range")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)

            Text("Move around the event to discover others")
                .font(.caption)
                .foregroundColor(.white.opacity(0.25))
                .padding(.top, 2)

            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared Helpers

    private func avatarView(name: String, avatarUrl: String?) -> some View {
        Group {
            if let avatarUrl, let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                    default:
                        initialsAvatar(name)
                    }
                }
            } else {
                initialsAvatar(name)
            }
        }
    }

    private func initialsAvatar(_ name: String) -> some View {
        let initials: String = {
            let parts = name.components(separatedBy: " ")
            if parts.count >= 2 {
                return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }()

        return ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.15))
                .frame(width: 44, height: 44)
            Text(initials)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.cyan.opacity(0.7))
        }
    }

    private func signalIcon(_ rssi: Int) -> String {
        switch rssi {
        case -40...0:    return "wifi"
        case -60..<(-40): return "wifi"
        case -80..<(-60): return "wifi"
        default:          return "wifi.exclamationmark"
        }
    }

    private func signalColor(_ rssi: Int) -> Color {
        switch rssi {
        case -40...0:    return .green
        case -60..<(-40): return .cyan
        case -80..<(-60): return .orange
        default:          return .red.opacity(0.6)
        }
    }
}
