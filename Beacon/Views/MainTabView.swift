import SwiftUI
import Combine

enum AppTab: Int {
    case home = 0
    case people = 1
    case event = 2
    case profile = 3

    // Legacy aliases for backward compatibility
    static let eventMode = AppTab.event
    static let network = AppTab.event
    static let myQR = AppTab.profile
}

struct MainTabView: View {
    let currentUser: User
    @Binding var selectedTab: AppTab

    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @State private var isConsumingPendingEvent = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(AppTab.home)

            NavigationStack {
                PeopleView()
            }
            .tabItem {
                Label("People", systemImage: "person.2.fill")
            }
            .tag(AppTab.people)

            ExploreView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Explore", systemImage: "safari")
                }
                .tag(AppTab.event)

            MyQRView(currentUser: currentUser)
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
                .tag(AppTab.profile)
        }
        .onAppear {
            #if DEBUG
            print("🚨 MainTabView appeared")
            #endif
            replayPendingEventIfNeeded(source: "onAppear")
        }
        .onReceive(deepLinkManager.$pendingEventId.removeDuplicates()) { pendingEventId in
            guard pendingEventId != nil else { return }
            #if DEBUG
            print("[DeepLink] 🟡 pendingEventId changed while MainTabView active: \(pendingEventId ?? "nil")")
            #endif
            replayPendingEventIfNeeded(source: "onReceive")
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            guard oldValue != newValue else { return }
            #if DEBUG
            print("[TAB-WRITE] \(oldValue) → \(newValue)")
            #endif
        }
    }

    // MARK: - Deep Link Replay

    private func replayPendingEventIfNeeded(source: String) {
        guard !isConsumingPendingEvent else {
            #if DEBUG
            print("[DeepLink] ⛔ Replay blocked (\(source)) — already consuming pending event")
            #endif
            return
        }

        guard let eventId = deepLinkManager.consumeEventId() else {
            #if DEBUG
            print("[DeepLink] 📭 No pending event to replay (\(source))")
            #endif
            return
        }

        isConsumingPendingEvent = true

        #if DEBUG
        print("[EventJoin] ✅ User-initiated join via deep link (source: \(source), eventId: \(eventId))")
        #endif

        selectedTab = .event

        Task {
            await EventJoinService.shared.joinEvent(eventID: eventId)

            await MainActor.run {
                self.isConsumingPendingEvent = false

                if EventJoinService.shared.isEventJoined {
                    selectedTab = .event
                }

                #if DEBUG
                if EventJoinService.shared.isEventJoined {
                    print("[DeepLink] ✅ Pending event join succeeded: \(eventId)")
                } else {
                    print("[DeepLink] ❌ Pending event join failed: \(eventId)")
                }
                #endif
            }
        }
    }
}
