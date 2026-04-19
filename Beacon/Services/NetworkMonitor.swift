import Foundation
import Network
import Combine

/// Minimal network availability signal using NWPathMonitor.
/// Publishes a simple online/offline state. No heavy subsystem.
@MainActor
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "nearify.network-monitor")

    private init() {
        // Capture a non-isolated reference to avoid the Swift 6 warning about
        // capturing @MainActor-isolated 'self' in concurrently-executing code.
        // The actual mutation happens safely inside Task { @MainActor }.
        let monitor = self.monitor
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isOnline != online {
                    self.isOnline = online
                    #if DEBUG
                    print("[Network] \(online ? "✅ online" : "⚠️ offline")")
                    #endif
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
