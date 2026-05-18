import Foundation

enum DebugLog {
    /// Important engineering diagnostics that should remain visible in DEBUG builds.
    static func diagnostic(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }

    /// Deep lifecycle/render diagnostics. Enable with the DEBUG_VERBOSE compilation condition.
    static func verbose(_ message: @autoclosure () -> String) {
        #if DEBUG_VERBOSE
        print(message())
        #endif
    }
}
