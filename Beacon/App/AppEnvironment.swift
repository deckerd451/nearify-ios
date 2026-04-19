import Foundation
import Supabase

final class AppEnvironment {

    static let shared = AppEnvironment()

    let supabaseClient: SupabaseClient

    /// Admin-only debug mode. Enable to access the Intelligence Debug panel.
    #if DEBUG
    static var isDebugMode: Bool = true
    #else
    static var isDebugMode: Bool = false
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
