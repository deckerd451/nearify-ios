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
    @State private var selectedTab: AppTab = .event
    @State private var showPostAuthTransition = true
    @State private var showReconnectionToast = false
    @State private var syncedEncounterCount = 0
    @StateObject private var messageCoordinator = MessageNotificationCoordinator.shared
    @State private var activeBannerConversation: BannerConversationDestination?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        print("🚨 DEBUG BUILD WITH APPDELEGATE INSTALLED")
        _ = NetworkMonitor.shared
        _ = BLEAdvertiserService.shared
        _ = BLEScannerService.shared
        _ = BeaconConfidenceService.shared
        _ = BeaconPresenceService.shared
        _ = EventPresenceService.shared
        _ = EventAttendeesService.shared
        _ = FeedService.shared
        _ = EncounterService.shared
        _ = MessagingService.shared
        _ = NotificationService.shared
        _ = MessageNotificationCoordinator.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated {
                    if let currentUser = authService.currentUser {
                        switch authService.profileState {
                        case .ready:
                            if showPostAuthTransition {
                                PostAuthTransitionView()
                                    .task {
                                        // Lightweight prep only.
                                        ExploreEventsService.shared.refresh()
                                        selectedTab = .event
                                        try? await Task.sleep(nanoseconds: 800_000_000)
                                        showPostAuthTransition = false
                                    }
                            } else {
                                ZStack(alignment: .top) {
                                    MainTabView(currentUser: currentUser, selectedTab: $selectedTab)

                                    // Nearby Mode banner — non-disruptive, auto-hides on recovery
                                    if authService.isOfflineMode {
                                        nearbyModeBanner
                                    }

                                    // Reconnection toast — shown briefly when connectivity returns
                                    if showReconnectionToast {
                                        ReconnectionToastView(syncedCount: syncedEncounterCount)
                                            .padding(.top, 4)
                                            .transition(.move(edge: .top).combined(with: .opacity))
                                    }

                                    if let banner = messageCoordinator.banner {
                                        IncomingMessageBannerView(banner: banner) {
                                            messageCoordinator.dismissBanner()
                                            Task {
                                                let convo = await MessagingService.shared.fetchConversationsSnapshot().first(where: { $0.id == banner.conversationId })
                                                if let convo {
                                                    await MessagingService.shared.fetchMessages(conversationId: convo.id)
                                                    activeBannerConversation = BannerConversationDestination(
                                                        targetProfileId: banner.senderProfileId,
                                                        targetName: banner.senderName,
                                                        conversation: convo
                                                    )
                                                }
                                            }
                                        } onDismiss: {
                                            messageCoordinator.dismissBanner()
                                        }
                                        .padding(.top, showReconnectionToast ? 56 : 4)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                    }
                                }
                                .animation(.easeInOut(duration: 0.3), value: authService.isOfflineMode)
                                .animation(.easeInOut(duration: 0.3), value: showReconnectionToast)
                                .onChange(of: authService.isOfflineMode) { wasOffline, isOffline in
                                    if wasOffline && !isOffline {
                                        // Just came back online — show reconnection toast
                                        syncedEncounterCount = 0
                                        showReconnectionToast = true
                                        #if DEBUG
                                        print("[NearbyMode] exiting (connection restored)")
                                        #endif
                                        // After a brief delay, update with actual sync count
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                            syncedEncounterCount = NearbyModeTracker.shared.lastSyncedCount
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                            withAnimation { showReconnectionToast = false }
                                        }
                                    }
                                    if !wasOffline && isOffline {
                                        #if DEBUG
                                        print("[NearbyMode] entered")
                                        #endif
                                        NearbyModeTracker.shared.startTracking()
                                    }
                                }
                            }

                        case .incomplete, .missing:
                            if authService.isOfflineMode {
                                // In Nearby Mode with incomplete profile, still show the app
                                ZStack(alignment: .top) {
                                    MainTabView(currentUser: currentUser, selectedTab: $selectedTab)
                                    nearbyModeBanner
                                }
                            } else {
                                ProfileCompletionView(profile: currentUser) {
                                    Task {
                                        await authService.refreshProfile()
                                    }
                                }
                            }
                        }
                    } else {
                        // No currentUser yet — still loading or failed
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
            .onAppear {
                if authService.isAuthenticated {
                    MessageNotificationCoordinator.shared.markForegroundActive()
                }
            }
            .sheet(item: $activeBannerConversation) { destination in
                ConversationView(
                    targetProfileId: destination.targetProfileId,
                    preloadedConversation: destination.conversation,
                    preloadedName: destination.targetName
                )
            }
            .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated {
                    showPostAuthTransition = true
                    MessageNotificationCoordinator.shared.markForegroundActive()
                } else {
                    showPostAuthTransition = true
                    selectedTab = .event
                    MessageNotificationCoordinator.shared.stop()
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
                    showPostAuthTransition = true
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
                    print("[DeepLink] 🎫 Event deep link: '\(eventId)'")
                    print("[DeepLink] 📥 Stored in DeepLinkManager — MainTabView will join when ready")
                    #endif
                    // Deep link event ID is stored in DeepLinkManager (above).
                    // MainTabView.replayPendingEventIfNeeded will join when UI is ready.
                    // DO NOT join here — it causes duplicate joins.
                    selectedTab = .event

                case .profile(let communityId):
                    #if DEBUG
                    print("[DeepLink] 👤 Profile: \(communityId)")
                    #endif
                    _ = communityId

                case .personalConnect(let eventId, let profileId):
                    #if DEBUG
                    print("[DeepLink] 🤝 Personal connect deep link: event=\(eventId), profile=\(profileId)")
                    #endif

                    Task {
                        do {
                            let result = try await ConnectionService.shared.createConnectionIfNeeded(to: profileId)
                            #if DEBUG
                            print("[DeepLink] ✅ Personal connect processed: \(result)")
                            #endif

                            if let currentUser = AuthService.shared.currentUser,
                               let eventUUID = UUID(uuidString: eventId),
                               let toProfileId = UUID(uuidString: profileId) {
                                NearifyIngestionService.shared.ingestQRConfirmedInteraction(
                                    eventId: eventUUID,
                                    fromProfileId: currentUser.id,
                                    toProfileId: toProfileId
                                )
                            }
                        } catch {
                            #if DEBUG
                            print("[DeepLink] ❌ Personal connect failed: \(error)")
                            #endif
                        }
                    }
                    selectedTab = .people
                }
            }
            // MARK: - Event Switch Confirmation
            //
            // Shown when the user attempts to join a different event while already in one.
            // The system NEVER silently switches events — user must confirm.
            .sheet(
                isPresented: Binding(
                    get: { EventJoinService.shared.pendingEventSwitch != nil },
                    set: { if !$0 { EventJoinService.shared.cancelEventSwitch() } }
                )
            ) {
                EventSwitchConfirmationSheet(
                    pending: EventJoinService.shared.pendingEventSwitch,
                    onCancel: {
                        EventJoinService.shared.cancelEventSwitch()
                    },
                    onConfirm: {
                        Task { await EventJoinService.shared.confirmEventSwitch() }
                    }
                )
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
            MessageNotificationCoordinator.shared.stop()
            // Persist local encounter data before backgrounding
            LocalEncounterStore.shared.stopCapture()

        case .active:
            #if DEBUG
            print("[Lifecycle] ☀️ App → active")
            #endif
            Task {
                await EventJoinService.shared.handleAppForeground()
            }
            MessageNotificationCoordinator.shared.markForegroundActive()
            // Resume local encounter capture if in an event or Nearby Mode
            if EventJoinService.shared.isEventJoined || AuthService.shared.isOfflineMode {
                LocalEncounterStore.shared.startCapture()
            }
            // Upload any pending encounter fragments
            LocalEncounterStore.shared.uploadPendingFragments()

        case .inactive:
            // Transitional state (e.g. notification center pulled down).
            // No action needed — don't treat as background.
            break

        @unknown default:
            break
        }
    }

    private struct BannerConversationDestination: Identifiable {
        let id = UUID()
        let targetProfileId: UUID
        let targetName: String
        let conversation: Conversation
    }

    private struct EventSwitchConfirmationSheet: View {
        let pending: EventJoinService.PendingEventSwitch?
        let onCancel: () -> Void
        let onConfirm: () -> Void

        var body: some View {
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()

                    VStack(alignment: .leading, spacing: 20) {
                        Text("Switch Events?")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)

                        if let pending {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("You’re currently checked in to:")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)

                                Text(pending.currentEventName)
                                    .font(.headline)
                                    .foregroundColor(.white)

                                Text("Leave this event and join:")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .padding(.top, 2)

                                Text(pending.newEventName ?? "Selected event")
                                    .font(.headline)
                                    .foregroundColor(.white)
                            }
                        }

                        HStack(spacing: 12) {
                            Button(action: onCancel) {
                                Text("Cancel")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.12))
                                    .cornerRadius(12)
                            }

                            Button(action: onConfirm) {
                                Text("Switch Events")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.blue)
                                    .cornerRadius(12)
                            }
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal)
                }
            }
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
    }

    private struct IncomingMessageBannerView: View {
        let banner: MessageNotificationCoordinator.InAppBanner
        let onTap: () -> Void
        let onDismiss: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.senderName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text(banner.preview)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 12)
            .onTapGesture(perform: onTap)
        }
    }

    // MARK: - Nearby Mode Banner

    private var nearbyModeBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
            Text("Nearby Mode")
                .font(.caption2)
                .fontWeight(.semibold)
            Text("·")
                .font(.caption2)
            Text("Bluetooth discovery active")
                .font(.caption2)
        }
        .foregroundColor(.cyan.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.cyan.opacity(0.12))
        .cornerRadius(8)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct LoginView: View {
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero
            VStack(spacing: 16) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.blue.opacity(0.8))

                Text("Meet the right people\nat live events")
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("Join an event and get real-time guidance\non who to talk to.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            // Sign-in buttons
            VStack(spacing: 12) {
                Button {
                    Task { await signInWithOAuth(provider: .google) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                        Text("Continue with Google")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isLoading)

                Button {
                    Task { await signInWithOAuth(provider: .github) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("Continue with GitHub")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
                }
                .disabled(isLoading)

                if isLoading {
                    ProgressView()
                        .padding(.top, 8)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
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

private struct PostAuthTransitionView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 42))
                    .foregroundColor(.cyan.opacity(0.9))
                Text("Nearify")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                ProgressView()
                    .tint(.white)
            }
        }
    }
}
