import SwiftUI
import Supabase
import Auth
import UserNotifications

struct AppRootView: View {
    @EnvironmentObject var auth: AppAuthService

    @State private var onboardingComplete: Bool? = nil
    @State private var didBootstrap = false

    private let onboarding = OnboardingService.shared

    var body: some View {
        content
            .task {
                guard !didBootstrap else { return }
                didBootstrap = true
                await auth.bootstrap()


            }
            .task(id: auth.session?.user.id) {
                await refreshOnboardingState()
            }
            .alert(
                auth.error?.title ?? "Fehler",
                isPresented: Binding(
                    get: { auth.error != nil },
                    set: { if !$0 { auth.error = nil } }
                )
            ) {
                Button("OK", role: .cancel) { auth.error = nil }
            } message: {
                Text(auth.error?.message ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if !didBootstrap {
            ProgressView()
        } else if auth.session == nil {
            WelcomeView()
        } else if onboardingComplete == nil {
            ProgressView()
        } else if onboardingComplete == false {
            OnboardingView(onFinished: handleOnboardingFinished)
        } else {
            MainAppTabsView()
        }
    }

    private func handleOnboardingFinished() {
        guard let userId = auth.session?.user.id else { return }
        Task {
            do {
                try await onboarding.setOnboardingComplete(userId: userId, complete: true)
                await MainActor.run { onboardingComplete = true }
            } catch {
                if Task.isCancelled { return }
                if error is CancellationError { return }

                await MainActor.run {
                    auth.error = AppError(
                        title: "Onboarding Update fehlgeschlagen",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    @MainActor
    private func refreshOnboardingState() async {
        guard let session = auth.session else {
            onboardingComplete = nil
            return
        }

        onboardingComplete = nil

        do {
            onboardingComplete = try await onboarding.fetchOnboardingComplete(userId: session.user.id)
        } catch {
            // This `.task(id:)` gets cancelled frequently when the view refreshes.
            // Cancellation is not a real error and should not show an alert.
            if Task.isCancelled { return }
            if error is CancellationError { return }

            // Default: show onboarding if we can't read the flag.
            onboardingComplete = false
            auth.error = AppError(
                title: "Onboarding Status Fehler",
                message: error.localizedDescription
            )
        }
    }
}

struct MainAppTabsView: View {
    @EnvironmentObject var auth: AppAuthService

    @State private var selectedTab: Int = 0
    @State private var selectedMatch: MatchesViewModel.MatchItem? = nil
    @State private var activeChatMatchId: UUID? = nil
    @State private var showDailyReward: Bool = false
    @StateObject private var matchesVM = MatchesViewModel()
    @StateObject private var rewardService = DailyRewardService.shared
    private var pushService: PushService { PushService.shared }

    private var totalUnread: Int {
        matchesVM.items.reduce(0) { $0 + $1.unreadCount }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView(onMatchChat: { item in
                selectedTab = 1
                activeChatMatchId = item.id
                selectedMatch = item
            })
                .tabItem { Label("Entdecken", systemImage: "flame.fill") }
                .tag(0)

            if let myId = auth.session?.user.id {
                MatchesView(myId: myId, activeChatMatchId: activeChatMatchId, vm: matchesVM) { item in
                    activeChatMatchId = item.id
                    selectedMatch = item
                }
                .tabItem { Label("Matches", systemImage: "bubble.left.and.bubble.right") }
                .badge(totalUnread > 0 ? totalUnread : 0)
                .tag(1)
            } else {
                ProgressView()
                    .tabItem { Label("Matches", systemImage: "bubble.left.and.bubble.right") }
                    .tag(1)
            }

            ProfileTabView()
                .tabItem { Label("Profil", systemImage: "person.fill") }
                .tag(2)
        }
        .sheet(item: $selectedMatch, onDismiss: {
            activeChatMatchId = nil
        }) { match in
            NavigationStack {
                ChatView(matchId: match.id, otherName: match.name, otherUserId: match.otherUserId)
                    .onDisappear { activeChatMatchId = nil }
            }
        }
        .sheet(isPresented: $showDailyReward) {
            DailyRewardView()
                .presentationDetents([.medium])
        }
        // On app launch: refresh reward state, show dialog once data is ready
        .task {
            rewardService.refresh()
        }
        // Reactive: show Daily Reward as soon as matches list finishes loading
        .onChange(of: matchesVM.isLoading) { _, loading in
            guard !loading, !showDailyReward else { return }
            rewardService.refresh()
            guard rewardService.canClaimToday else { return }
            showDailyReward = true
        }
        // Foreground: merged single observer for badge reset + reward refresh
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            rewardService.refresh()
            Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
            if rewardService.canClaimToday { showDailyReward = true }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 { Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) } }
        }
        // Deep-link from push: retry until matchesVM.items is available
        .onChange(of: pushService.pendingMatchId) { _, matchId in
            guard let matchId else { return }
            pushService.pendingMatchId = nil
            selectedTab = 1
            if let item = matchesVM.items.first(where: { $0.id == matchId }) {
                activeChatMatchId = item.id
                selectedMatch = item
            } else {
                // Items not yet loaded – wait for next update
                Task {
                    for _ in 0..<10 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if let item = matchesVM.items.first(where: { $0.id == matchId }) {
                            await MainActor.run {
                                activeChatMatchId = item.id
                                selectedMatch = item
                            }
                            return
                        }
                    }
                }
            }
        }
    }
}
