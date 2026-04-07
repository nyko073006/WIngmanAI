//
//  DiscoverView.swift
//  WingmanAI
//
//  Created by Nyko on 09.02.26.
//

import SwiftUI
import Combine
import Auth
import Supabase
#if canImport(UIKit)
import UIKit
#endif

fileprivate let brandColor = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)
fileprivate let brandColorAlt = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)

fileprivate enum SwipeLabel { case like, nope }

/// Lightweight Identifiable wrapper for UUID, used in .sheet(item:) bindings.
struct IdentifiableUUID: Identifiable {
    let id: UUID
    var distanceKm: Int? = nil
}

struct DiscoverView: View {
    @EnvironmentObject var auth: AppAuthService
    @StateObject private var vm = DiscoverViewModel()
    @StateObject private var usageLimits = UsageLimitService.shared

    /// Called when user taps "Chat starten" on the match overlay.
    /// Parent can use this to switch to the Matches tab and open the chat.
    var onMatchChat: ((MatchesViewModel.MatchItem) -> Void)? = nil

    @State private var pendingChatMatchId: UUID? = nil
    @State private var pendingChatOtherName: String = ""
    @State private var pendingChatOtherUserId: UUID? = nil
    @State private var pendingHookDraft: String = ""
    @State private var pendingChatInitialDraft: String = ""
    @State private var profileSheetUser: IdentifiableUUID? = nil
    @State private var blockAlertTarget: IdentifiableUUID? = nil
    @State private var reportTarget: IdentifiableUUID? = nil
    @State private var reportTargetName: String = ""
    @State private var pendingReportReason: String? = nil
    @State private var showSearchSettings: Bool = false
    @State private var showLikesView: Bool = false
    @State private var showSubscription: Bool = false
    @State private var pendingLikesCount: Int = 0
    @State private var moderationError: String? = nil

    @AppStorage("discover_swipe_hint_shown") private var swipeHintShown: Bool = false

    // Swipe UI
    @State private var cardOffset: CGSize = .zero
    @State private var didHapticThreshold: Bool = false
    @State private var swipeLabel: SwipeLabel? = nil

    private let swipeThreshold: CGFloat = 120

    private var swipeProgress: CGFloat {
        let p = min(1, abs(cardOffset.width) / swipeThreshold)
        return max(0, p)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Image("colored-logo-ohne-schrift")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 36)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 14) {
                            // Likes button
                            Button {
                                showLikesView = true
                            } label: {
                                Image(systemName: "heart.fill")
                                    .font(.body)
                                    .foregroundStyle(pendingLikesCount > 0 ? brandColor : Color(.systemGray3))
                            }
                            .accessibilityLabel(pendingLikesCount > 0 ? "Likes anzeigen (\(pendingLikesCount))" : "Likes anzeigen")
                            .overlay(alignment: .topTrailing) {
                                if pendingLikesCount > 0 {
                                    ZStack {
                                        Circle().fill(brandColor).frame(width: 16, height: 16)
                                        Text(pendingLikesCount > 9 ? "9+" : "\(pendingLikesCount)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .offset(x: 7, y: -7)
                                }
                            }

                            // Filter button
                            Button {
                                showSearchSettings = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.body)
                            }
                            .accessibilityLabel("Sucheinstellungen")
                            .overlay(alignment: .topTrailing) {
                                if vm.hasActiveFilters {
                                    Circle()
                                        .fill(brandColor)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 3, y: -3)
                                }
                            }
                        }
                    }
                }
                .refreshable { await reload() }
                .navigationDestination(
                    isPresented: Binding(
                        get: { pendingChatMatchId != nil },
                        set: { active in if !active { pendingChatMatchId = nil } }
                    )
                ) {
                    if let id = pendingChatMatchId, let otherUserId = pendingChatOtherUserId {
                        ChatView(matchId: id, otherName: pendingChatOtherName, otherUserId: otherUserId, initialDraft: pendingChatInitialDraft)
                            .onAppear { pendingChatInitialDraft = "" }
                    } else {
                        EmptyView()
                    }
                }
        }
        .task(id: auth.session?.user.id) {
            if let myId = auth.session?.user.id {
                await vm.loadFilterDefaults(myUserId: myId)
            }
            await reload()
            await loadLikesCount()
        }
        .sheet(isPresented: $showLikesView, onDismiss: {
            Task { await loadLikesCount() }
        }) {
            if let myId = auth.session?.user.id {
                LikesView(myId: myId)
            }
        }
        .sheet(item: $profileSheetUser) { wrapper in
            OtherUserProfileSheet(
                userId: wrapper.id,
                distanceKm: wrapper.distanceKm,
                onRespondToHook: { hook in
                    pendingHookDraft = hook
                    profileSheetUser = nil
                    Task {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            cardOffset = CGSize(width: 900, height: 0)
                        }
                        await swipe(isLike: true)
                    }
                },
                onBlockOrReport: {
                    let userId = wrapper.id
                    profileSheetUser = nil
                    Task {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            cardOffset = CGSize(width: -900, height: 0)
                        }
                        try? await Task.sleep(nanoseconds: 280_000_000)
                        vm.removeFromStack(userId: userId)
                        cardOffset = .zero
                    }
                }
            )
        }
        .sheet(isPresented: $showSearchSettings) {
            SearchSettingsSheet(vm: vm, myUserId: auth.session?.user.id)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $vm.showSwipeLimitSheet) {
            SubscriptionView()
        }
        .sheet(isPresented: $vm.showRewindLimitSheet) {
            SubscriptionView()
        }
        .sheet(isPresented: $showSubscription) {
            SubscriptionView()
        }
        .alert("Blockieren?", isPresented: Binding(
            get: { blockAlertTarget != nil },
            set: { if !$0 { blockAlertTarget = nil } }
        )) {
            Button("Blockieren", role: .destructive) {
                if let t = blockAlertTarget, let myId = auth.session?.user.id {
                    Task { await vm.blockUser(myUserId: myId, targetId: t.id) }
                }
                blockAlertTarget = nil
            }
            Button("Abbrechen", role: .cancel) { blockAlertTarget = nil }
        } message: {
            Text("Dieser Nutzer wird blockiert und dir nicht mehr angezeigt.")
        }
        .confirmationDialog("Melden: \(reportTargetName)", isPresented: Binding(
            get: { reportTarget != nil },
            set: { if !$0 { reportTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Spam") { pendingReportReason = "Spam" }
            Button("Belästigung") { pendingReportReason = "Belästigung" }
            Button("Fake-Profil") { pendingReportReason = "Fake-Profil" }
            Button("Unangemessene Fotos") { pendingReportReason = "Unangemessene Fotos" }
            Button("Sonstiges") { pendingReportReason = "Sonstiges" }
            Button("Abbrechen", role: .cancel) { reportTarget = nil }
        }
        .confirmationDialog("Auch blockieren?", isPresented: Binding(
            get: { pendingReportReason != nil },
            set: { if !$0 { pendingReportReason = nil } }
        ), titleVisibility: .visible) {
            Button("Nur melden") {
                guard let reason = pendingReportReason else { return }
                sendReport(reason, alsoBlock: false)
            }
            Button("Melden und blockieren", role: .destructive) {
                guard let reason = pendingReportReason else { return }
                sendReport(reason, alsoBlock: true)
            }
            Button("Abbrechen", role: .cancel) { pendingReportReason = nil }
        } message: {
            Text("Wenn du auch blockierst, wird dir dieser Nutzer nicht mehr angezeigt.")
        }
        .alert("Fehler", isPresented: Binding(
            get: { moderationError != nil },
            set: { if !$0 { moderationError = nil } }
        )) {
            Button("OK", role: .cancel) { moderationError = nil }
        } message: {
            Text(moderationError ?? "")
        }
        .fullScreenCover(isPresented: $vm.showMatchAlert) {
            MatchOverlayView(
                name: vm.matchedUser?.displayName ?? "Match!",
                photoUrl: vm.matchedUserPhotoUrl,
                onChat: {
                    let matchId    = vm.matchedMatchId
                    let user       = vm.matchedUser
                    let photoUrl   = vm.matchedUserPhotoUrl
                    vm.showMatchAlert    = false
                    vm.matchedUser       = nil
                    vm.matchedMatchId    = nil
                    vm.matchedUserPhotoUrl = nil

                    if let mid = matchId, let user {
                        let item = MatchesViewModel.MatchItem(
                            id: mid,
                            otherUserId: user.id,
                            name: user.displayName,
                            photoUrl: photoUrl,
                            lastMessageAt: nil,
                            lastMessageText: nil,
                            subtitle: nil,
                            unreadCount: 0
                        )
                        if let onMatchChat {
                            onMatchChat(item)
                        } else {
                            pendingChatInitialDraft  = pendingHookDraft
                            pendingHookDraft         = ""
                            pendingChatMatchId       = mid
                            pendingChatOtherName     = user.displayName
                            pendingChatOtherUserId   = user.id
                        }
                    }
                },
                onContinue: {
                    vm.showMatchAlert = false
                    vm.matchedUser = nil
                    vm.matchedMatchId = nil
                    vm.matchedUserPhotoUrl = nil
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Lade Profile…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else if let err = vm.errorText {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Erneut versuchen") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
                    .tint(brandColor)
            }
            .padding()
        } else if !usageLimits.canSwipe() {
            NoSwipesView(
                usedToday: usageLimits.current.swipesPerDay - usageLimits.remainingSwipes,
                dailyLimit: usageLimits.current.swipesPerDay,
                onUpgrade: { showSubscription = true }
            )
        } else if vm.currentProfile != nil {
            let stack = Array(vm.profiles.prefix(3))
            GeometryReader { geo in
            let cardH = max(460, geo.size.height - 108)

            VStack(spacing: 6) {
                ZStack {
                    ForEach(Array(stack.enumerated()).reversed(), id: \.element.id) { idx, prof in
                        let isTop = (idx == 0)
                        let depth = min(idx, 2)
                        let baseY = CGFloat(depth) * 10
                        let baseScale = 1.0 - (CGFloat(depth) * 0.03)

                        let lift = (idx == 1) ? (swipeProgress * 10) : (idx == 2 ? (swipeProgress * 6) : 0)
                        let scaleBoost = (idx == 1) ? (swipeProgress * 0.02) : (idx == 2 ? (swipeProgress * 0.01) : 0)

                        let y = baseY - lift
                        let scale = baseScale + scaleBoost

                        Group {
                            let photoUrls: [String] = {
                                let all = vm.allPhotosByUserId[prof.id] ?? []
                                if !all.isEmpty { return all }
                                if let primary = vm.primaryPhotoByUserId[prof.id] { return [primary] }
                                return []
                            }()

                            if isTop {
                                SwipeableProfileCard(
                                    profile: prof,
                                    photoUrls: photoUrls,
                                    cardHeight: cardH,
                                    offset: $cardOffset,
                                    label: $swipeLabel,
                                    threshold: swipeThreshold,
                                    isDisabled: vm.isSwiping || vm.isLoading,
                                    onShowProfile: { profileSheetUser = IdentifiableUUID(id: prof.id, distanceKm: prof.distanceKm) }
                                ) { isLike in
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        cardOffset = CGSize(width: isLike ? 900 : -900, height: 0)
                                    }
                                    if !swipeHintShown { swipeHintShown = true }
                                    Task {
                                        hapticImpact(.medium)
                                        await swipe(isLike: isLike)
                                        // offset/label reset handled by onChange(vm.currentProfile?.id)
                                    }
                                } onThresholdCross: { _ in
                                    if !didHapticThreshold {
                                        didHapticThreshold = true
                                        hapticImpact(.light)
                                    }
                                } onThresholdExit: {
                                    didHapticThreshold = false
                                }
                                .contextMenu {
                                    Button {
                                        blockAlertTarget = IdentifiableUUID(id: prof.id)
                                    } label: {
                                        Label("Blockieren", systemImage: "hand.raised")
                                    }
                                    Button(role: .destructive) {
                                        reportTarget = IdentifiableUUID(id: prof.id)
                                        reportTargetName = prof.displayName
                                    } label: {
                                        Label("Melden", systemImage: "flag")
                                    }
                                }
                            } else {
                                ProfileCard(profile: prof, photoUrls: photoUrls, cardHeight: cardH)
                                    .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(scale)
                        .offset(y: y)
                        .opacity(isTop ? 1.0 : (0.90 + Double(swipeProgress) * 0.06))
                    }
                }
                .frame(height: cardH + 14) // compact stack peek keeps more room for the photo
                // Reset offset as soon as the top card changes (new profile becomes top)
                // This prevents the next card from briefly inheriting the fly-off offset.
                .onChange(of: vm.currentProfile?.id) { _, _ in
                    cardOffset = .zero
                    swipeLabel = nil
                    didHapticThreshold = false
                    preloadUpcomingCards()
                }

                // Undo button (only after a swipe, disappears after use or on match)
                if vm.lastSwipedProfile != nil {
                    Button {
                        guard let myId = auth.session?.user.id else { return }
                        let wasLike = vm.lastSwipeWasLike
                        Task {
                            await vm.undoSwipe(myUserId: myId)
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                                cardOffset = CGSize(width: wasLike ? 220 : -220, height: 0)
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                                cardOffset = .zero
                            }
                        }
                    } label: {
                        Label("Zurück", systemImage: "arrow.uturn.left")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Action buttons
                HStack(spacing: 10) {
                    Spacer()

                    // Nein
                    VStack(spacing: 4) {
                        Button {
                            Task {
                                hapticImpact(.light)
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    cardOffset = CGSize(width: -900, height: 0)
                                }
                                if !swipeHintShown { swipeHintShown = true }
                                await swipe(isLike: false)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .shadow(color: Color.black.opacity(0.10), radius: 10, y: 4)
                                Image(systemName: "xmark")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(Color(.systemGray))
                            }
                            .frame(width: 64, height: 64)
                        }
                        .accessibilityLabel("Nein")
                        .disabled(vm.isSwiping || vm.isLoading)
                        Text("Nein")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(.systemGray))
                    }

                    Spacer()

                    // Super Like
                    VStack(spacing: 4) {
                        Button {
                            Task {
                                hapticImpact(.medium)
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    cardOffset = CGSize(width: 0, height: -900)
                                }
                                if !swipeHintShown { swipeHintShown = true }
                                await swipe(isLike: true)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(red: 0.48, green: 0.22, blue: 0.92),
                                                     Color(red: 0.85, green: 0.32, blue: 0.98)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                                    .shadow(color: Color.purple.opacity(0.28), radius: 12, y: 5)
                                Image(systemName: "star.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 58, height: 58)
                        }
                        .accessibilityLabel("Super Like")
                        .disabled(vm.isSwiping || vm.isLoading)
                        Text("Super")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(red: 0.6, green: 0.25, blue: 0.95))
                    }

                    Spacer()

                    // Ja / Like
                    VStack(spacing: 4) {
                        Button {
                            Task {
                                hapticImpact(.medium)
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    cardOffset = CGSize(width: 900, height: 0)
                                }
                                if !swipeHintShown { swipeHintShown = true }
                                await swipe(isLike: true)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(colors: [brandColor, brandColorAlt],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                                    .shadow(color: brandColor.opacity(0.35), radius: 12, y: 5)
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 23, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 64, height: 64)
                        }
                        .accessibilityLabel("Like")
                        .disabled(vm.isSwiping || vm.isLoading)
                        .symbolEffect(.bounce, value: vm.isSwiping)
                        Text("Ja")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(brandColor)
                    }

                    Spacer()
                }
                .frame(height: 84)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                if !swipeHintShown {
                    SwipeHintView()
                        .padding(.bottom, 92)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    swipeHintShown = true
                                }
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            VStack(spacing: 20) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(brandColor)

                VStack(spacing: 8) {
                    Text("Du hast alle gesehen!")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("Neue Leute kommen täglich dazu.\nSchau später nochmal rein.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                Button {
                    Task { await reload() }
                } label: {
                    Label("Neu laden", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(colors: [brandColor, brandColorAlt],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                        .shadow(color: brandColor.opacity(0.35), radius: 10, y: 5)
                }
                .buttonStyle(.plain)

                if let myId = auth.session?.user.id {
                    if vm.isRelaxed {
                        Button("Striktere Suche") {
                            Task { await vm.setRelaxed(false, myUserId: myId) }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        Button("Suche erweitern") {
                            Task { await vm.setRelaxed(true, myUserId: myId) }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(brandColor)
                    }
                }
            }
            .padding(32)
        }
    }

    private func loadLikesCount() async {
        guard let myId = auth.session?.user.id else { return }
        let revealedIds: Set<UUID> = {
            let stored = UserDefaults.standard.stringArray(forKey: "likes_revealed_ids") ?? []
            return Set(stored.compactMap { UUID(uuidString: $0) })
        }()
        do {
            struct Row: Decodable { let swiper_id: UUID }
            let rows: [Row] = try await SupabaseClientProvider.shared.client
                .from("swipes")
                .select("swiper_id")
                .eq("target_id", value: myId.uuidString)
                .eq("is_like", value: true)
                .execute()
                .value
            pendingLikesCount = rows.filter { !revealedIds.contains($0.swiper_id) }.count
        } catch {
            // non-critical
        }
    }

    private func sendReport(_ reason: String, alsoBlock: Bool) {
        guard let t = reportTarget, let myId = auth.session?.user.id else {
            pendingReportReason = nil
            reportTarget = nil
            return
        }
        pendingReportReason = nil

        Task {
            do {
                try await SwipeService.shared.report(reporterId: myId, reportedId: t.id, reason: reason)
                if alsoBlock {
                    await vm.blockUser(myUserId: myId, targetId: t.id)
                }
            } catch {
                moderationError = AppError.userMessage(for: error)
            }
        }
        reportTarget = nil
    }

    private func reload() async {
        guard let myId = auth.session?.user.id else { return }
        await vm.load(myUserId: myId)
        preloadUpcomingCards()
    }

    private func preloadUpcomingCards() {
        let upcoming = vm.profiles.dropFirst()
        for prof in upcoming.prefix(3) {
            let urls = (vm.allPhotosByUserId[prof.id] ?? [])
            let toPreload = urls.isEmpty ? (vm.primaryPhotoByUserId[prof.id].map { [$0] } ?? []) : urls
            for urlString in toPreload.prefix(2) {
                if let url = URL(string: urlString) {
                    Task.detached(priority: .background) {
                        await ImageCache.shared.preload(url)
                    }
                }
            }
        }
    }

    private func swipe(isLike: Bool) async {
        guard let myId = auth.session?.user.id else { return }
        await vm.swipe(myUserId: myId, isLike: isLike)
    }

    private func hapticImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }

    private struct SwipeHintView: View {
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "hand.draw.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))

                VStack(alignment: .leading, spacing: 3) {
                    Text("So funktioniert's")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Label("Nein", systemImage: "arrow.left")
                        Label("Ja", systemImage: "arrow.right")
                        Label("Super", systemImage: "arrow.up")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle().fill(brandColor).frame(width: 6, height: 6)
                    Circle().fill(Color.white.opacity(0.45)).frame(width: 6, height: 6)
                    Circle().fill(Color.white.opacity(0.28)).frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - No Swipes View

private struct NoSwipesView: View {
    let usedToday: Int
    let dailyLimit: Int
    let onUpgrade: () -> Void

    @State private var timeUntilReset: String = ""
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [brandColor.opacity(0.15), brandColorAlt.opacity(0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 110, height: 110)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(
                            LinearGradient(colors: [brandColor, brandColorAlt],
                                           startPoint: .top, endPoint: .bottom)
                        )
                }

                // Title + subtitle
                VStack(spacing: 10) {
                    Text("Tageslimit erreicht")
                        .font(.system(.title2, design: .rounded).weight(.bold))

                    Text("Du hast heute alle \(dailyLimit) Swipes verbraucht.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    // Reset countdown pill
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.caption.weight(.semibold))
                        Text("Reset in \(timeUntilReset)")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(brandColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(brandColor.opacity(0.10), in: Capsule())
                }

                // Tier comparison cards
                VStack(spacing: 10) {
                    TierRow(
                        icon: "bolt.fill",
                        color: .orange,
                        title: "Premium",
                        detail: "50 Swipes pro Tag",
                        isHighlighted: false
                    )
                    TierRow(
                        icon: "crown.fill",
                        color: Color(red: 0.55, green: 0.22, blue: 0.92),
                        title: "Elite",
                        detail: "Unbegrenzte Swipes",
                        isHighlighted: true
                    )
                }
                .padding(.horizontal, 4)

                // Upgrade CTA
                Button(action: onUpgrade) {
                    HStack(spacing: 10) {
                        Image(systemName: "crown.fill")
                            .font(.body.weight(.semibold))
                        Text("Jetzt upgraden")
                            .font(.body.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [brandColor, brandColorAlt],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: brandColor.opacity(0.35), radius: 12, y: 6)
                }
                .buttonStyle(.plain)

                Text("Swipes werden täglich um Mitternacht zurückgesetzt.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
        }
        .onAppear { updateCountdown() }
        .onReceive(timer) { _ in updateCountdown() }
    }

    private func updateCountdown() {
        let cal = Calendar.current
        guard let midnight = cal.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) else {
            timeUntilReset = "Morgen"
            return
        }
        let diff = Int(midnight.timeIntervalSince(Date()))
        let h = diff / 3600
        let m = (diff % 3600) / 60
        if h > 0 {
            timeUntilReset = "\(h) Std. \(m) Min."
        } else {
            timeUntilReset = "\(m) Min."
        }
    }

    private struct TierRow: View {
        let icon: String
        let color: Color
        let title: String
        let detail: String
        let isHighlighted: Bool

        var body: some View {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isHighlighted {
                    Text("Beliebt")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(color, in: Capsule())
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isHighlighted ? color.opacity(0.35) : Color.clear, lineWidth: 1.5)
                    )
            )
        }
    }
}

// MARK: - Search Settings Sheet

private struct SearchSettingsSheet: View {
    @ObservedObject var vm: DiscoverViewModel
    let myUserId: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var ageMin: Double = 18
    @State private var ageMax: Double = 45
    @State private var distanceKm: Double = 50
    @State private var unlimitedDistance: Bool = false
    @State private var lookingFor: String = "_all_"
    @State private var interestedIn: Set<String> = []
    @State private var isRelaxed: Bool = false

    private let genders = ["Frauen", "Männer", "Divers"]

    /// Normalize any gender value (English/mixed) → German UI label used by chips
    private func normalizeToLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "women", "weiblich", "female": return "Frauen"
        case "men", "männlich", "male":     return "Männer"
        case "divers", "diverse":            return "Divers"
        default: return raw
        }
    }
    private let lookingForOpts: [(String, String, String)] = [
        ("serious",     "infinity",       "Etwas Ernstes"),
        ("casual",      "sparkles",       "Etwas Lockeres"),
        ("friends",     "person.2.fill",  "Neue Freunde"),
        ("open_to_all", "heart",          "Bin offen")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // Distance
                    filterSection(title: "Entfernung", icon: "location.circle.fill") {
                        VStack(spacing: 12) {
                            HStack {
                                Text(unlimitedDistance ? "Unbegrenzt" : "\(Int(distanceKm)) km")
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                    .foregroundStyle(brandColor)
                                Spacer()
                                Toggle("Unbegrenzt", isOn: $unlimitedDistance)
                                    .labelsHidden()
                                    .tint(brandColor)
                            }
                            if !unlimitedDistance {
                                Slider(value: $distanceKm, in: 5...200, step: 5)
                                    .tint(brandColor)
                                HStack {
                                    Text("5 km").font(.caption2).foregroundStyle(.tertiary)
                                    Spacer()
                                    Text("200 km").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    // Age
                    filterSection(title: "Alter", icon: "figure.2") {
                        VStack(spacing: 14) {
                            HStack {
                                Text("\(Int(ageMin))–\(Int(ageMax)) Jahre")
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                    .foregroundStyle(brandColor)
                                Spacer()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Von: \(Int(ageMin))").font(.caption).foregroundStyle(.secondary)
                                Slider(
                                    value: $ageMin,
                                    in: 18...max(19.0, ageMax - 1),
                                    step: 1
                                ) { _ in if ageMin >= ageMax { ageMax = min(80, ageMin + 1) } }
                                .tint(brandColor)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bis: \(Int(ageMax))").font(.caption).foregroundStyle(.secondary)
                                Slider(
                                    value: $ageMax,
                                    in: min(79.0, ageMin + 1)...80,
                                    step: 1
                                ) { _ in if ageMax <= ageMin { ageMin = max(18, ageMax - 1) } }
                                .tint(brandColor)
                            }
                        }
                    }

                    // Interested in
                    filterSection(title: "Ich möchte sehen", icon: "person.2.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                ForEach(genders, id: \.self) { g in
                                    filterChip(
                                        label: g,
                                        isOn: interestedIn.isEmpty || interestedIn.contains(g)
                                    ) {
                                        if interestedIn.isEmpty {
                                            // First tap: select only this one
                                            interestedIn = Set(genders.filter { $0 != g })
                                        } else if interestedIn.contains(g) {
                                            interestedIn.remove(g)
                                            if interestedIn.isEmpty { interestedIn = [] } // = all
                                        } else {
                                            interestedIn.insert(g)
                                            if interestedIn.count == genders.count { interestedIn = [] }
                                        }
                                    }
                                }
                            }
                            Text(interestedIn.isEmpty ? "Alle anzeigen" : genders.filter { interestedIn.contains($0) }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Looking for
                    filterSection(title: "Ich suche", icon: "heart.circle.fill") {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(lookingForOpts.prefix(2), id: \.0) { val, icon, label in
                                    lookingForChip(val: val, icon: icon, label: label)
                                }
                            }
                            HStack(spacing: 8) {
                                ForEach(lookingForOpts.dropFirst(2), id: \.0) { val, icon, label in
                                    lookingForChip(val: val, icon: icon, label: label)
                                }
                            }
                            if lookingFor == "_all_" {
                                Text("Alle Suchziele werden angezeigt")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    // Relaxed mode
                    filterSection(title: "Filter lockern", icon: "magnifyingglass.circle.fill") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Erweiterte Suche")
                                    .font(.subheadline.weight(.medium))
                                Text("±2 Jahre · +50 % Distanz (max. 100 km)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $isRelaxed)
                                .labelsHidden()
                                .tint(brandColor)
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .navigationTitle("Sucheinstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurücksetzen") {
                        guard let id = myUserId else { return }
                        Task { await vm.resetFilters(myUserId: id); dismiss() }
                    }
                    .font(.subheadline)
                    .foregroundStyle(vm.hasActiveFilters ? brandColor : .secondary)
                    .disabled(!vm.hasActiveFilters)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abbrechen") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    commitToVM()
                    guard let id = myUserId else { dismiss(); return }
                    Task { await vm.applyFilters(myUserId: id); dismiss() }
                } label: {
                    Text("Anwenden")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [brandColor, brandColorAlt],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: brandColor.opacity(0.35), radius: 10, y: 5)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear { syncFromVM() }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func filterSection<Content: View>(
        title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func filterChip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isOn ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isOn ? brandColor : Color(.systemGray5))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func lookingForChip(val: String, icon: String, label: String) -> some View {
        let isOn = lookingFor == val
        Button { lookingFor = isOn ? "_all_" : val } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.semibold))
                Text(label).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isOn ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isOn ? brandColor : Color(.systemGray5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - State sync

    private func syncFromVM() {
        // Guard: ageMax must always be > ageMin to avoid Slider precondition crash
        let rawMin = max(18, vm.filterAgeMin)
        let rawMax = max(rawMin + 1, min(80, vm.filterAgeMax))
        ageMin = Double(rawMin)
        ageMax = Double(rawMax)
        unlimitedDistance = vm.filterDistanceKm >= 9999
        distanceKm = unlimitedDistance ? 100 : Double(vm.filterDistanceKm)
        lookingFor = vm.filterLookingFor
        interestedIn = vm.filterInterestedIn == "_all_"
            ? []
            : Set(vm.filterInterestedIn.split(separator: ",").map { normalizeToLabel(String($0)) })
        isRelaxed = vm.isRelaxed
    }

    private func commitToVM() {
        vm.filterAgeMin = Int(ageMin)
        vm.filterAgeMax = Int(ageMax)
        vm.filterDistanceKm = unlimitedDistance ? 9999 : Int(distanceKm)
        vm.filterLookingFor = lookingFor
        vm.filterInterestedIn = interestedIn.isEmpty ? "_all_" : interestedIn.sorted().joined(separator: ",")
        vm.isRelaxed = isRelaxed
    }
}

// MARK: - UI Pieces

private struct SwipeableProfileCard: View {
    let profile: PublicProfile
    let photoUrls: [String]
    let cardHeight: CGFloat

    @Binding var offset: CGSize
    @Binding var label: SwipeLabel?

    let threshold: CGFloat
    let isDisabled: Bool
    var onShowProfile: (() -> Void)? = nil

    let onCommit: (Bool) -> Void
    let onThresholdCross: (SwipeLabel) -> Void
    let onThresholdExit: () -> Void

    private var rotation: Angle { .degrees(Double(offset.width / 22)) }

    private var likeOpacity: Double {
        let v = max(0, min(1, (offset.width - threshold) / 80))
        return Double(v)
    }

    private var nopeOpacity: Double {
        let v = max(0, min(1, (-offset.width - threshold) / 80))
        return Double(v)
    }

    var body: some View {
        ProfileCard(profile: profile, photoUrls: photoUrls, cardHeight: cardHeight, onShowProfile: onShowProfile)
            .overlay(alignment: .topLeading) {
                if likeOpacity > 0 {
                    swipeStamp(text: "LIKE", systemImage: "heart.fill", color: brandColor)
                        .opacity(likeOpacity)
                        .padding(16)
                }
            }
            .overlay(alignment: .topTrailing) {
                if nopeOpacity > 0 {
                    swipeStamp(text: "NOPE", systemImage: "xmark", color: .gray)
                        .opacity(nopeOpacity)
                        .padding(16)
                }
            }
            .offset(offset)
            .rotationEffect(rotation)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        guard !isDisabled else { return }
                        offset = v.translation

                        if offset.width > threshold {
                            label = .like
                            onThresholdCross(.like)
                        } else if offset.width < -threshold {
                            label = .nope
                            onThresholdCross(.nope)
                        } else {
                            if label != nil { onThresholdExit() }
                            label = nil
                        }
                    }
                    .onEnded { v in
                        guard !isDisabled else { return }
                        let x = v.translation.width
                        if x > threshold {
                            onCommit(true)
                        } else if x < -threshold {
                            onCommit(false)
                        } else {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                                offset = .zero
                                label = nil
                            }
                            onThresholdExit()
                        }
                    }
            )
    }

    private func swipeStamp(text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .black))
            Text(text)
                .font(.system(.callout, design: .rounded).weight(.black))
                .kerning(1.5)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .background(
            LinearGradient(
                colors: text == "LIKE" ? [brandColor, brandColorAlt] : [Color(.systemGray2), Color(.systemGray3)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(Capsule())
        .shadow(color: color.opacity(0.45), radius: 12, y: 5)
        .rotationEffect(text == "LIKE" ? .degrees(-8) : .degrees(8))
    }
}

private struct ProfileCard: View {
    let profile: PublicProfile
    let photoUrls: [String]
    let cardHeight: CGFloat
    var onShowProfile: (() -> Void)? = nil

    @State private var photoIndex: Int = 0

    private var age: Int? {
        guard let dateStr = profile.birthdate else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: dateStr) else { return nil }
        let years = Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
        return years > 0 ? years : nil
    }

    var body: some View {
        // GeometryReader gives exact pixel dimensions → scaledToFill won't escape bounds
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                // Full-bleed photo with exact pixel frame
                photoArea(w: w, h: h)

                // Gradient overlay: transparent top, soft dark bottom
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.48),
                        .init(color: .black.opacity(0.46), location: 0.78),
                        .init(color: .black.opacity(0.82), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: w, height: h)

                // Photo dots — top center
                if photoUrls.count > 1 {
                    VStack {
                        HStack(spacing: 5) {
                            ForEach(0..<photoUrls.count, id: \.self) { i in
                                Capsule()
                                    .fill(i == photoIndex ? Color.white : Color.white.opacity(0.40))
                                    .frame(width: i == photoIndex ? 18 : 6, height: 4)
                                    .animation(.easeInOut(duration: 0.2), value: photoIndex)
                            }
                        }
                        .padding(.top, 14)
                        Spacer()
                    }
                    .frame(width: w, height: h)
                }

                // Tap zones for photo navigation (left 40% / right 40%)
                if photoUrls.count > 1 {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: w * 0.4, height: h)
                            .contentShape(Rectangle())
                            .onTapGesture { if photoIndex > 0 { photoIndex -= 1 } }
                        Spacer()
                        Color.clear
                            .frame(width: w * 0.4, height: h)
                            .contentShape(Rectangle())
                            .onTapGesture { if photoIndex < photoUrls.count - 1 { photoIndex += 1 } }
                    }
                    .frame(width: w, height: h)
                }

                // Profile info overlay at bottom
                VStack(alignment: .leading, spacing: 8) {
                    // Name + age
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(profile.displayName.isEmpty ? "Unbekannt" : profile.displayName)
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                        if let a = age {
                            Text("\(a)")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.80))
                        }
                    }

                    // City + distance
                    HStack(spacing: 10) {
                        if let city = profile.city, !city.isEmpty {
                            Label(city, systemImage: "mappin")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if let km = profile.distanceKm {
                            Text(km < 1 ? "< 1 km" : "\(km) km")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.70))
                        }
                        if let label = profile.activityLabel {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(label == "Gerade aktiv" ? Color.green : Color.white.opacity(0.55))
                                    .frame(width: 6, height: 6)
                                Text(label)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.80))
                            }
                        }
                    }

                    // Bio
                    if !profile.bio.isEmpty {
                        Text(profile.bio)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                    }

                    // Interest chips
                    if !profile.interests.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(profile.interests.prefix(4), id: \.self) { interest in
                                    Text(interest)
                                        .font(.caption2.weight(.medium))
                                        .fontWeight(.medium)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(.white.opacity(0.18), in: Capsule())
                                        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
                                }
                            }
                            .padding(.horizontal, 1)
                        }
                        .padding(.top, 2)
                    }

                    // Full profile button
                    if let onShowProfile {
                        Button(action: onShowProfile) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.rectangle")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Vollständiges Profil")
                                    .font(.caption.weight(.semibold))
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.20), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.30), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
                .frame(width: w, alignment: .leading)
            }
            .frame(width: w, height: h)
        }
        .frame(height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: brandColor.opacity(0.12), radius: 24, y: 12)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    @ViewBuilder
    private func photoArea(w: CGFloat, h: CGFloat) -> some View {
        let url = photoUrls.indices.contains(photoIndex)
            ? URL(string: photoUrls[photoIndex])
            : nil

        if let url {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: h)
                        .clipped()
                case .empty:
                    Color(.systemGray5).frame(width: w, height: h)
                        .overlay(ProgressView())
                case .failure:
                    Color(.systemGray5).frame(width: w, height: h)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        )
                }
            }
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGray4), Color(.systemGray5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "person.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(width: w, height: h)
        }
    }
}

private struct MatchOverlayView: View {
    let name: String
    let photoUrl: String?
    let onChat: () -> Void
    let onContinue: () -> Void

    @State private var sparkles: [MatchSparkle] = []
    @State private var titleScale: CGFloat = 0.4
    @State private var titleOpacity: Double = 0
    @State private var avatarScale: CGFloat = 0.6
    @State private var avatarOpacity: Double = 0
    @State private var buttonsOffset: CGFloat = 60
    @State private var buttonsOpacity: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.90),
                    brandColor.opacity(0.35),
                    Color.black.opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Sparkle particles
            GeometryReader { geo in
                ForEach(sparkles) { s in
                    Image(systemName: s.symbol)
                        .font(.system(size: s.size))
                        .foregroundStyle(s.color)
                        .opacity(s.opacity)
                        .scaleEffect(s.scale)
                        .position(x: s.x * geo.size.width, y: s.y * geo.size.height)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 28) {

                // ── Title block ───────────────────────────────────────────
                VStack(spacing: 10) {
                    // Glowing heart icon
                    ZStack {
                        Circle()
                            .fill(brandColor.opacity(0.22))
                            .frame(width: 68, height: 68)
                            .blur(radius: 12)
                        Image(systemName: "heart.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(colors: [brandColor, brandColorAlt],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .shadow(color: brandColor.opacity(0.7), radius: 14, y: 4)
                    }

                    // Gradient title
                    if #available(iOS 18.0, *) {
                        Text("Du hast ein Match! 🎉")
                            .font(.system(size: 36, weight: .heavy, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(colors: [.white, brandColorAlt.mix(with: .white, by: 0.3)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .multilineTextAlignment(.center)
                            .shadow(color: brandColor.opacity(0.45), radius: 10, y: 3)
                    } else {
                        // Fallback on earlier versions
                    }

                    Text("Du und \(name) habt euch geliked ✨")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .scaleEffect(titleScale)
                .opacity(titleOpacity)

                // ── Avatar ───────────────────────────────────────────────
                avatar
                    .frame(width: 170, height: 170)
                    .clipShape(Circle())
                    // Inner glow ring
                    .overlay(
                        Circle().stroke(
                            LinearGradient(colors: [brandColor, brandColorAlt],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 3.5
                        )
                    )
                    // Outer soft ring
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
                            .padding(-6)
                    )
                    .shadow(color: brandColor.opacity(0.55), radius: 28, y: 10)
                    .scaleEffect(avatarScale)
                    .opacity(avatarOpacity)

                // ── Buttons ──────────────────────────────────────────────
                VStack(spacing: 14) {
                    Button(action: onChat) {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.callout.weight(.semibold))
                            Text("Chat starten")
                                .font(.headline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(colors: [brandColor, brandColorAlt],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .shadow(color: brandColor.opacity(0.45), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)

                    Button(action: onContinue) {
                        Text("Weiter swipen")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white.opacity(0.75))
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
                            .overlay(
                                RoundedRectangle(cornerRadius: 28)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .offset(y: buttonsOffset)
                .opacity(buttonsOpacity)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
        }
        .onAppear { runEntrance() }
    }

    private func runEntrance() {
        // Title pop-in
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) {
            titleScale = 1; titleOpacity = 1
        }
        // Avatar bounce
        withAnimation(.spring(response: 0.55, dampingFraction: 0.55).delay(0.25)) {
            avatarScale = 1; avatarOpacity = 1
        }
        // Buttons slide up
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.45)) {
            buttonsOffset = 0; buttonsOpacity = 1
        }
        // Sparkles burst
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            spawnSparkles()
        }
    }

    private func spawnSparkles() {
        let symbols = ["sparkle", "heart.fill", "star.fill", "sparkles"]
        let colors: [Color] = [brandColor, brandColorAlt, .white, .yellow, .pink]
        var newSparkles: [MatchSparkle] = []
        for i in 0..<28 {
            let s = MatchSparkle(
                id: i,
                symbol: symbols[i % symbols.count],
                x: CGFloat.random(in: 0.05...0.95),
                y: CGFloat.random(in: 0.02...0.85),
                size: CGFloat.random(in: 10...22),
                color: colors[i % colors.count],
                opacity: 0,
                scale: 0
            )
            newSparkles.append(s)
        }
        sparkles = newSparkles
        // Animate in staggered
        for i in sparkles.indices {
            let delay = Double(i) * 0.035
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(delay)) {
                sparkles[i].opacity = Double.random(in: 0.6...1.0)
                sparkles[i].scale = CGFloat.random(in: 0.8...1.4)
            }
            // Fade out
            withAnimation(.easeOut(duration: 0.6).delay(delay + 0.8)) {
                sparkles[i].opacity = 0
                sparkles[i].scale = 0.2
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let s = photoUrl, let url = URL(string: s) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Circle().fill(Color.white.opacity(0.10))
                        ProgressView().tint(.white)
                    }
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Circle().fill(Color.white.opacity(0.12))
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(.white.opacity(0.55))
                        )
                }
            }
        } else {
            Circle().fill(Color.white.opacity(0.12))
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                )
        }
    }
}


private struct MatchSparkle: Identifiable {
    let id: Int
    let symbol: String
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let color: Color
    var opacity: Double
    var scale: CGFloat
}
