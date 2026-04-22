import Foundation

@MainActor
struct PersonalQREventContext {
    let eventId: UUID
    let eventName: String?
}

@MainActor
final class PersonalQRContextResolver {
    static let shared = PersonalQRContextResolver()

    private var lastLoggedState: String?

    private init() {}

    func resolve() -> PersonalQREventContext? {
        let eventJoin = EventJoinService.shared

        if eventJoin.isEventJoined,
           let activeEventId = eventJoin.currentEventID,
           let eventUUID = UUID(uuidString: activeEventId) {
            logOnce("[PersonalQR] Using active event \(activeEventId) (\(eventJoin.currentEventName ?? "unknown"))")
            return PersonalQREventContext(
                eventId: eventUUID,
                eventName: eventJoin.currentEventName
            )
        }

        if let reconnect = eventJoin.reconnectContext,
           let reconnectUUID = UUID(uuidString: reconnect.eventId) {
            logOnce("[PersonalQR] Falling back to last event \(reconnect.eventId) (\(reconnect.eventName))")
            return PersonalQREventContext(
                eventId: reconnectUUID,
                eventName: reconnect.eventName
            )
        }

        logOnce("[PersonalQR] No event context available")
        return nil
    }

    private func logOnce(_ message: String) {
        guard lastLoggedState != message else { return }
        lastLoggedState = message
        #if DEBUG
        print(message)
        #endif
    }
}
