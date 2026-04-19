import SwiftUI

/// Compact status card shown at the top of Home when in Nearby Mode.
/// Communicates that the app is intentionally operating locally via BLE.
struct NearbyModeCardView: View {
    @ObservedObject private var scanner = BLEScannerService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.cyan)

                Text("Nearby Mode")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()
            }

            Text("Discover people around you using Bluetooth")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))

            // Status indicators
            HStack(spacing: 16) {
                statusPill(
                    icon: "dot.radiowaves.left.and.right",
                    label: "Bluetooth",
                    value: scanner.isScanning ? "On" : "Ready",
                    isActive: true
                )

                statusPill(
                    icon: "icloud.slash",
                    label: "Cloud Sync",
                    value: "Paused",
                    isActive: false
                )
            }

            Text("Full features return when connection is restored")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.cyan.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }

    private func statusPill(icon: String, label: String, value: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(isActive ? .green : .orange.opacity(0.7))

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))

            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isActive ? .green : .orange.opacity(0.7))
        }
    }
}

/// Reconnection toast shown briefly when connectivity returns.
/// Shows sync count when nearby encounters were saved locally.
struct ReconnectionToastView: View {
    var syncedCount: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.icloud")
                .font(.system(size: 11))
            Text(message)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.8))
        .cornerRadius(10)
    }

    private var message: String {
        if syncedCount > 0 {
            return syncedCount == 1
                ? "Connection restored — 1 encounter synced"
                : "Connection restored — \(syncedCount) encounters synced"
        }
        return "Connection restored — syncing"
    }
}
