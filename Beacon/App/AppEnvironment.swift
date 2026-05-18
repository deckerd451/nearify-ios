import Foundation
import Supabase

final class AppEnvironment {

    static let shared = AppEnvironment()

    let supabaseClient: SupabaseClient

    /// Admin-only debug mode. Opt in explicitly so internal TestFlight builds do not surface developer tooling by default.
    #if DEBUG
    static var isDebugMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-NearifyDebugMode") ||
        UserDefaults.standard.bool(forKey: "nearify.debugMode.enabled")
    }
    #else
    static var isDebugMode: Bool { false }
    #endif

    // MARK: - Share Configuration

    /// Centralized install destination URL for the share system.
    /// Currently points to TestFlight. Change this single value to switch
    /// to App Store URL — no other code changes required.
    static let nearifyShareInstallURL = URL(string: "https://testflight.apple.com/join/ZayvEbAy")!

    private init() {

        let supabaseURL = URL(string: "https://unndeygygkgodmmdnlup.supabase.co")!

        let supabaseKey = "sb_publishable_G0KAfCFTovYCWDeEEKWBfg_8UpPHWWZ"


        supabaseClient = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            options: .init(
                auth: .init(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }
}
