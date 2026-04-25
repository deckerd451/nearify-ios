import Foundation

enum ContactSyncContext: Equatable, CustomStringConvertible {
    case eventWrapUp
    case userExplicitAction
    case arrived
    case foundEachOther
    case proximityDetection
    case bleMatch
    case connectionState
    case unknown(String)

    var description: String {
        switch self {
        case .eventWrapUp: return "eventWrapUp"
        case .userExplicitAction: return "userExplicitAction"
        case .arrived: return "arrived"
        case .foundEachOther: return "foundEachOther"
        case .proximityDetection: return "proximityDetection"
        case .bleMatch: return "bleMatch"
        case .connectionState: return "connectionState"
        case .unknown(let source): return "unknown(\(source))"
        }
    }
}

enum ContactSyncTrigger {
    static func runIfEligible(
        context: ContactSyncContext,
        operation: () async -> Void
    ) async {
        guard context == .eventWrapUp || context == .userExplicitAction else {
            print("[ContactSync] BLOCKED: context = \(context)")
            return
        }

        guard context == .eventWrapUp else {
            print("[ContactSync] BLOCKED: context = \(context)")
            return
        }

        await operation()
    }
}
