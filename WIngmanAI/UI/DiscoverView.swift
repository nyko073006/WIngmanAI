//
//  DiscoverView.swift
//  WingmanAI
//
//  Created by Nyko on 09.02.26.
//

import SwiftUI
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

    /// Called when user taps "Chat starten" on the match overlay.
    /// Parent can use this to switch to the Matches tab and open the chat.
    var onMatchChat: ((MatchesViewModel.MatchItem) -> Void)? = nil

    @State private var pendingChatMatchId: UUID? = nil
    @State private var pendingChatOtherName: String = ""
    @State private var pendingChatOtherUserId: UUID? = nil
    @State private var profileSheetUser: IdentifiableUUID? = nil
    @State private var blockAlertTarget: IdentifiableUUID? = nil
    @State private var reportTarget: IdentifiableUUID? = nil
    @State private var reportTargetName: String = ""
    @State private var showSearchSettings: Bool = false
    @State private var showLikesView: Bool = false
    @State private var pendingLikesCount: Int = 0

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
                            .frame(height: 42)
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
                                if vm.isRelaxed {
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
                        ChatView(matchId: id, otherName: pendingChatOtherName, otherUserId: otherUserId)
                    } else {
                        EmptyView()
                    }
                }
        }
        .task(id: auth.session?.user.id) {
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
            OtherUserProfileSheet(userId: wrapper.id, distanceKm: wrapper.distanceKm)
        }
        .sheet(isPresented: $showSearchSettings) {
            SearchSettingsSheet(vm: vm, myUserId: auth.session?.user.id)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $vm.showSwipeLimitSheet) {
            SubscriptionView()
        }
        .sheet(isPresented: $vm.showRewindLimitSheet) {
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
            Button("Spam") { sendReport("Spam") }
            Button("Belästigung") { sendReport("Belästigung") }
            Button("Fake-Profil") { sendReport("Fake-Profil") }
            Button("Unangemessene Fotos") { sendReport("Unangemessene Fotos") }
            Button("Sonstiges") { sendReport("Sonstiges") }
            Button("Abbrechen", role: .cancel) { reportTarget = nil }
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
                            pendingChatMatchId   = mid
                            pendingChatOtherName = user.displayName
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
            VStack(spacing: 12) {
                Text("Fehler")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Neu laden") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        } else if vm.currentProfile != nil {
            let stack = Array(vm.profiles.prefix(3))
            let cardH: CGFloat = 480

            VStack(spacing: 16) {
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
                .frame(height: cardH + 20) // +20 for card-stack peek offset
                // Reset offset as soon as the top card changes (new profile becomes top)
                // This prevents the next card from briefly inheriting the fly-off offset.
                .onChange(of: vm.currentProfile?.id) { _, _ in
                    cardOffset = .zero
                    swipeLabel = nil
                    didHapticThreshold = false
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
                HStack(spacing: 44) {
                    // Nope
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
                                .fill(Color(.systemBackground))
                                .shadow(color: Color(.systemGray4).opacity(0.5), radius: 12, y: 5)
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color(.systemGray2))
                        }
                        .frame(width: 64, height: 64)
                    }
                    .accessibilityLabel("Nope")
                    .disabled(vm.isSwiping || vm.isLoading)

                    // Like
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
                                .shadow(color: brandColor.opacity(0.5), radius: 18, y: 8)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 80, height: 80)
                    }
                    .accessibilityLabel("Like")
                    .disabled(vm.isSwiping || vm.isLoading)
                    .symbolEffect(.bounce, value: vm.isSwiping)
                }
                .frame(height: 96)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                if !swipeHintShown {
                    SwipeHintView()
                        .padding(.bottom, 104)
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

    private func sendReport(_ reason: String) {
        guard let t = reportTarget, let myId = auth.session?.user.id else { reportTarget = nil; return }
        Task { try? await SwipeService.shared.report(reporterId: myId, reportedId: t.id, reason: reason) }
        reportTarget = nil
    }

    private func reload() async {
        guard let myId = auth.session?.user.id else { return }
        await vm.load(myUserId: myId)
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
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "hand.draw")
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Swipe")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text("Links = Nope · Rechts = Like")
                        .font(.caption)
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

// MARK: - Search Settings Sheet

private struct SearchSettingsSheet: View {
    @ObservedObject var vm: DiscoverViewModel
    let myUserId: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sucheinstellungen")
                        .font(.system(.headline, design: .rounded))
                    Text("Passe an, wen du siehst")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fertig") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(brandColor)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            Toggle(isOn: Binding(
                get: { vm.isRelaxed },
                set: { newVal in
                    guard let id = myUserId else { return }
                    Task { await vm.setRelaxed(newVal, myUserId: id) }
                }
            )) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(vm.isRelaxed ? brandColor.opacity(0.15) : Color(.systemGray5))
                            .frame(width: 38, height: 38)
                        Image(systemName: vm.isRelaxed ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .foregroundStyle(vm.isRelaxed ? brandColor : .secondary)
                            .font(.system(size: 17, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Erweiterte Suche")
                            .font(.body.weight(.medium))
                        Text("±2 Jahre · +50 % Distanz (max. 100 km)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(brandColor)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Dein Radius und Alter-Filter werden im Profil gesetzt.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Spacer()
        }
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

    private var rotation: Angle { .degrees(Double(offset.width / 32)) }

    private var tiltX: Double {
        let maxTilt = 8.0
        let v = max(-1.0, min(1.0, Double(offset.height / 220)))
        return -v * maxTilt
    }

    private var tiltY: Double {
        let maxTilt = 10.0
        let v = max(-1.0, min(1.0, Double(offset.width / 240)))
        return v * maxTilt
    }

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
            .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.85)
            .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.85)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: offset)
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
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
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
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.55), location: 0.75),
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
                VStack(alignment: .leading, spacing: 7) {
                    // Name + age
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(profile.displayName.isEmpty ? "Unbekannt" : profile.displayName)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                        if let a = age {
                            Text("\(a)")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.80))
                        }
                    }

                    // City + distance
                    HStack(spacing: 10) {
                        if let city = profile.city, !city.isEmpty {
                            Label(city, systemImage: "mappin")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if let km = profile.distanceKm {
                            Text(km < 1 ? "< 1 km" : "\(km) km")
                                .font(.subheadline)
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
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                    }

                    // Interest chips
                    if !profile.interests.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(profile.interests.prefix(8), id: \.self) { interest in
                                    Text(interest)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
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
                        HStack {
                            Spacer()
                            Button(action: onShowProfile) {
                                HStack(spacing: 5) {
                                    Text("Mehr sehen")
                                    Image(systemName: "chevron.up")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.18), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
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
                    Text("Du hast ein Match! 🎉")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [.white, brandColorAlt.mix(with: .white, by: 0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .multilineTextAlignment(.center)
                        .shadow(color: brandColor.opacity(0.45), radius: 10, y: 3)

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
