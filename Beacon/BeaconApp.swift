//
//  BeaconApp.swift
//  Beacon
//
//  Created by Douglas Hamilton on 3/6/26.
//

import SwiftUI
import Supabase

@main
struct BeaconApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authService = AuthService.shared
    @State private var selectedTab: AppTab = .home
    @Environment(\.scenePhase) private var scenePhase

    init() {
        print("🚨 DEBUG BUILD WITH APPDELEGATE INSTALLED")
        _ = BLEAdvertiserService.shared
        _ = BLEScannerService.shared
        _ = BeaconConfidenceService.shared
        _ = EventPresenceService.shared
        _ = EventAttendeesService.shared
        _ = FeedService.shared
        _ = EncounterService.shared
        _ = MessagingService.shared
        _ = NotificationService.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated {
                    if let currentUser = authService.currentUser {
                        switch authService.profileState {
                        case .ready:
                            MainTabView(currentUser: currentUser, selectedTab: $selectedTab)

                        case .incomplete, .missing:
                            ProfileCompletionView(profile: currentUser) {
                                Task {
                                    await authService.refreshProfile()
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading profile…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    LoginView()
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
            .onOpenURL { url in
                let urlString = url.absoluteString
                print("🚨 onOpenURL fired:", urlString)
                #if DEBUG
                print("[DeepLink] 🔗 Received URL: \(urlString)")
                #endif

                if urlString.hasPrefix("beacon://callback") {
                    #if DEBUG
                    print("[DeepLink] 🔐 Routing to OAuth")
                    #endif
                    Task { await authService.handleOAuthCallback(url: url) }
                    return
                }

                DeepLinkManager.shared.handle(url: url)

                guard let payload = QRService.parse(from: urlString) else {
                    #if DEBUG
                    print("[DeepLink] ❓ Unknown or unsupported URL: \(urlString)")
                    #endif
                    return
                }

                switch payload {
                case .event(let eventId):
                    #if DEBUG
                    print("[DeepLink] 🎫 Event: '\(eventId)'")
                    print("[DeepLink] 📱 Switching to Network tab (UI signal)")
                    #endif
                    selectedTab = .event
                    Task {
                        #if DEBUG
                        print("[DeepLink] 🎫 Routing to EventJoinService")
                        #endif
                        await EventJoinService.shared.joinEvent(eventID: eventId)
                        #if DEBUG
                        if EventJoinService.shared.isEventJoined {
                            print("[DeepLink] ✅ Join succeeded: '\(eventId)'")
                        } else {
                            let err = EventJoinService.shared.joinError ?? "unknown error"
                            print("[DeepLink] ❌ Join failed for '\(eventId)': \(err)")
                        }
                        #endif
                    }

                case .profile(let communityId):
                    #if DEBUG
                    print("[DeepLink] 👤 Profile: \(communityId)")
                    #endif
                    _ = communityId
                }
            }
        }
    }

    // MARK: - Scene Phase Lifecycle

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            #if DEBUG
            print("[Lifecycle] 🌙 App → background")
            #endif
            EventJoinService.shared.handleAppBackground()

        case .active:
            #if DEBUG
            print("[Lifecycle] ☀️ App → active")
            #endif
            Task {
                await EventJoinService.shared.handleAppForeground()
            }

        case .inactive:
            // Transitional state (e.g. notification center pulled down).
            // No action needed — don't treat as background.
            break

        @unknown default:
            break
        }
    }
}

struct LoginView: View {
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Nearify")
                .font(.largeTitle)
                .fontWeight(.bold)

            VStack(spacing: 12) {
                Button {
                    Task {
                        await signInWithOAuth(provider: .google)
                    }
                } label: {
                    HStack {
                        Image(systemName: "globe")
                        Text("Continue with Google")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)

                Button {
                    Task {
                        await signInWithOAuth(provider: .github)
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("Continue with GitHub")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
    }

    private func signInWithOAuth(provider: Provider) async {
        isLoading = true
        errorMessage = nil

        do {
            try await AuthService.shared.signInWithOAuth(provider: provider)
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
