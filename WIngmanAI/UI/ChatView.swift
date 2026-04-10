//
//  ChatView.swift
//  WingmanAI
//
//  Created by Nyko on 12.02.26.
//

import SwiftUI
import Auth
import Combine
import PhotosUI

private let chatBrand    = Color(.sRGB, red: 0xE8/255, green: 0x60/255, blue: 0x7A/255, opacity: 1)
private let chatBrandAlt = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)

struct ChatView: View {
    @EnvironmentObject var auth: AppAuthService
    @Environment(\.dismiss) private var dismiss

    let matchId: UUID
    let otherName: String
    let otherUserId: UUID

    @StateObject private var vm = ChatViewModel()
    @State private var draft: String

    init(matchId: UUID, otherName: String, otherUserId: UUID, initialDraft: String = "") {
        self.matchId = matchId
        self.otherName = otherName
        self.otherUserId = otherUserId
        self._draft = State(initialValue: initialDraft)
    }
    @FocusState private var isTextFocused: Bool
    @State private var imagePickerItem: PhotosPickerItem? = nil
    @State private var fullscreenImageUrl: URL? = nil
    @StateObject private var premium = PremiumService.shared
    @State private var showSubscription = false
    @State private var reactedIds: Set<UUID> = []
    @State private var showReportDialog = false
    @State private var showBlockAlert = false
    @State private var pendingReportReason: String? = nil

    // True when the last message in the conversation was sent by us
    private var lastMessageIsFromMe: Bool {
        guard let myId = auth.session?.user.id,
              let last = vm.messages.last else { return false }
        return last.senderId == myId
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isOffline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                    Text("Offline – Nachrichten werden gesendet, sobald du wieder verbunden bist.")
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
            if lastMessageIsFromMe || vm.isLoadingWingSuggestions || vm.wingmanResponse != nil {
                Divider()
                WingmanBar(
                    response: vm.wingmanResponse,
                    isLoading: vm.isLoadingWingSuggestions,
                    waitingForReply: lastMessageIsFromMe,
                    onTap: { s in
                        draft = s
                        vm.wingmanResponse = nil
                        AnalyticsService.shared.track(.wingmanSuggestionTapped)
                    },
                    onGenerateMore: {
                        if UsageLimitService.shared.canUseAI() {
                            UsageLimitService.shared.recordAIUse()
                            Task { await vm.loadWingSuggestions(matchId: matchId, otherName: otherName) }
                        } else {
                            showSubscription = true
                        }
                    }
                )
            }
            Divider()
            composer
        }
        .animation(.easeInOut(duration: 0.25), value: vm.isOffline)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Zurück")
                            .font(.body)
                    }
                    .foregroundStyle(chatBrand)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(otherName).font(.headline)
                    if vm.otherIsTyping {
                        TypingDotsView()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { showReportDialog = true } label: {
                        Label("Melden", systemImage: "flag")
                    }
                    Button(role: .destructive) { showBlockAlert = true } label: {
                        Label("Blockieren", systemImage: "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Regenerate button — costs 1 credit (first load on open is free)
                Button {
                    if UsageLimitService.shared.canUseAI() {
                        UsageLimitService.shared.recordAIUse()
                        AnalyticsService.shared.track(.wingmanUsed, properties: ["trigger": "manual"])
                        Task { await vm.loadWingSuggestions(matchId: matchId, otherName: otherName) }
                    } else {
                        showSubscription = true
                    }
                } label: {
                    if vm.isLoadingWingSuggestions {
                        ProgressView().scaleEffect(0.8)
                    } else if lastMessageIsFromMe {
                        Image(systemName: "sparkles")
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "hourglass")
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundStyle(.secondary)
                                    .offset(x: 4, y: -4)
                            }
                            .foregroundStyle(.secondary)
                    } else {
                        let hasCredits = UsageLimitService.shared.canUseAI()
                        Image(systemName: "sparkles")
                            .overlay(alignment: .topTrailing) {
                                if !hasCredits {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundStyle(chatBrand)
                                        .offset(x: 4, y: -4)
                                }
                            }
                    }
                }
                .accessibilityLabel(lastMessageIsFromMe ? "Warte auf Antwort" : (UsageLimitService.shared.canUseAI() ? "Neue Vorschläge (-1 Credit)" : "Vorschläge (Keine Credits)"))
                .disabled(vm.isLoadingWingSuggestions || lastMessageIsFromMe)
            }
        }
        .task(id: matchId) {
            guard let myId = auth.session?.user.id else { return }
            vm.setMyUserId(myId)
            loadReactions()
            await vm.loadInitial(matchId: matchId)
            await vm.startRealtime(matchId: matchId)
            // First auto-load is always free (no credit consumed) — only regenerate costs credits
            if !lastMessageIsFromMe && !vm.isLoadingWingSuggestions {
                await vm.loadWingSuggestions(matchId: matchId, otherName: otherName)
            }
        }
        .refreshable {
            await vm.loadInitial(matchId: matchId)
        }
        .fullScreenCover(item: Binding(
            get: { fullscreenImageUrl.map { FullscreenImageItem(url: $0) } },
            set: { fullscreenImageUrl = $0?.url }
        )) { item in
            FullscreenImageView(url: item.url)
        }
        .sheet(isPresented: $showSubscription) { SubscriptionView() }
        .onDisappear {
            Task { await vm.stopRealtime() }
        }
        .alert("Fehler", isPresented: Binding(
            get: { vm.errorText != nil },
            set: { if !$0 { vm.errorText = nil } }
        )) {
            Button("OK", role: .cancel) { vm.errorText = nil }
        } message: {
            Text(vm.errorText ?? "")
        }
        .alert("Blockieren?", isPresented: $showBlockAlert) {
            Button("Blockieren", role: .destructive) {
                guard let myId = auth.session?.user.id else { return }
                Task {
                    do {
                        try await SwipeService.shared.block(blockerId: myId, blockedId: otherUserId)
                        dismiss()
                    } catch {
                        vm.errorText = AppError.userMessage(for: error)
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dieser Nutzer wird für dich blockiert.")
        }
        .confirmationDialog("Melden", isPresented: $showReportDialog, titleVisibility: .visible) {
            ForEach(["Spam", "Belästigung", "Fake-Profil", "Unangemessene Fotos", "Sonstiges"], id: \.self) { reason in
                Button(reason) {
                    pendingReportReason = reason
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Auch blockieren?", isPresented: Binding(
            get: { pendingReportReason != nil },
            set: { if !$0 { pendingReportReason = nil } }
        ), titleVisibility: .visible) {
            Button("Nur melden") {
                guard let reason = pendingReportReason else { return }
                submitReport(reason: reason, alsoBlock: false)
            }
            Button("Melden und blockieren", role: .destructive) {
                guard let reason = pendingReportReason else { return }
                submitReport(reason: reason, alsoBlock: true)
            }
            Button("Abbrechen", role: .cancel) { pendingReportReason = nil }
        } message: {
            Text("Wenn du auch blockierst, wird dir dieser Nutzer nicht mehr angezeigt.")
        }
    }

    private func submitReport(reason: String, alsoBlock: Bool) {
        guard let myId = auth.session?.user.id else {
            pendingReportReason = nil
            return
        }
        pendingReportReason = nil

        Task {
            do {
                try await SwipeService.shared.report(reporterId: myId, reportedId: otherUserId, reason: reason)
                if alsoBlock {
                    try await SwipeService.shared.block(blockerId: myId, blockedId: otherUserId)
                    dismiss()
                }
            } catch {
                vm.errorText = AppError.userMessage(for: error)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.messages.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Lade Nachrichten…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.messages.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    OtherUserProfileSheet(userId: otherUserId, isEmbedded: true)
                    icebreakerSection
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {

                        if vm.hasMore {
                            Button {
                                Task { await vm.loadMore(matchId: matchId) }
                            } label: {
                                HStack(spacing: 8) {
                                    if vm.isLoadingMore { ProgressView().scaleEffect(0.9) }
                                    Text(vm.isLoadingMore ? "Lade…" : "Ältere laden")
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }

                        let myId = auth.session?.user.id
                        let lastMineId = vm.messages.last(where: { myId == $0.senderId })?.id

                        ForEach(Array(vm.messages.enumerated()), id: \.element.id) { index, m in
                            let showDate: Bool = {
                                if index == 0 { return true }
                                return !Calendar.current.isDate(m.createdAt, inSameDayAs: vm.messages[index - 1].createdAt)
                            }()
                            if showDate {
                                ChatDateSeparator(date: m.createdAt)
                            }
                            let isMine = myId == m.senderId
                            let isLastRead = isMine
                                && m.id == lastMineId
                                && vm.otherLastSeenAt.map { $0 >= m.createdAt } == true
                            let msgId = m.id
                            MessageBubble(
                                text: m.text,
                                isMine: isMine,
                                timestamp: m.createdAt,
                                status: m.status,
                                isLastRead: isLastRead,
                                isReacted: reactedIds.contains(m.id),
                                onImageTap: { url in fullscreenImageUrl = url },
                                onRetry: isMine ? { Task { await vm.retry(messageId: msgId, matchId: matchId) } } : nil,
                                onReact: { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { toggleReaction(messageId: m.id) } }
                            )
                            .id(m.id)
                        }
                        if vm.otherIsTyping {
                            TypingBubble()
                                .id("typing")
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                        }
                    }
                    .padding(12)
                }
                .background(Color(.systemGroupedBackground))
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: vm.messages.last?.id) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: vm.otherIsTyping) { _, isTyping in
                    if isTyping {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isTextFocused) { _, focused in
                    if focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                            scrollToBottom(proxy)
                        }
                    }
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
    }

    private var icebreakerSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(chatBrand)
                Text("Noch keine Nachrichten")
                    .font(.headline)
                Text("Wingman hat ein paar Ideen 💡")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(icebreakers(for: otherName), id: \.self) { msg in
                    Button {
                        draft = msg
                        isTextFocused = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkle")
                                .font(.caption)
                                .foregroundStyle(chatBrand)
                            Text(msg)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.circle")
                                .foregroundStyle(chatBrand.opacity(0.6))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(chatBrand.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("AI Co-Pilot · Tippe auf eine Idee, um sie anzupassen")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 32)
    }

    private func icebreakers(for name: String) -> [String] {
        let first = name.components(separatedBy: " ").first ?? name
        return [
            LocalIcebreakerGenerator.make(name: first, city: nil, bio: "", interests: []),
            "Hey \(first) 😄 Was war dein letztes Abenteuer – egal ob groß oder klein?",
            "Hey \(first) ✨ Wenn du morgen irgendwo auf der Welt aufwachen könntest: Wo wäre das?"
        ]
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 10) {
            let isUploading = vm.isUploadingImage
            PhotosPicker(selection: $imagePickerItem, matching: .images) {
                Image(systemName: isUploading ? "arrow.up.circle.fill" : "photo.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isUploading ? Color.secondary : chatBrand)
                    .frame(width: 38, height: 38)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
                    .accessibilityLabel(isUploading ? "Lädt Foto hoch" : "Foto auswählen")
            }
            .disabled(isUploading || vm.isSending)
            .onChange(of: imagePickerItem) { _, item in
                guard let item, let myId = auth.session?.user.id else { return }
                imagePickerItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    await vm.sendImage(matchId: matchId, senderId: myId, imageData: data)
                }
            }

            TextField("Nachricht…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(.systemGray6))
                        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                )
                .focused($isTextFocused)
                .disabled(vm.isSending)
                .onChange(of: draft) { _, _ in
                    vm.userDidType(matchId: matchId)
                }
                .onSubmit {
                    Task { await send() }
                }
                .frame(minHeight: 40)

            Button {
                Task { await send() }
            } label: {
                Image(systemName: vm.isSending ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(Color.secondary.opacity(0.35))
                            : AnyShapeStyle(LinearGradient(colors: [chatBrand, chatBrandAlt], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .clipShape(Circle())
                    .accessibilityLabel(vm.isSending ? "Sendet Nachricht" : "Nachricht senden")
            }
            .disabled(vm.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private func send() async {
        guard let myId = auth.session?.user.id else {
            vm.errorText = "Nicht eingeloggt."
            return
        }

        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip accidental [IMG] prefix from user-typed text (images go via photo picker)
        let text = raw.hasPrefix("[IMG]") ? String(raw.dropFirst(5)) : raw
        guard !text.isEmpty else { return }

        draft = ""
        isTextFocused = false
        await vm.send(matchId: matchId, senderId: myId, text: text)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: AnyHashable = vm.otherIsTyping ? AnyHashable("typing") : (vm.messages.last.map { AnyHashable($0.id) } ?? AnyHashable("typing"))
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private func reactionsKey() -> String { "reactions_\(matchId.uuidString)" }

    private func loadReactions() {
        let stored = UserDefaults.standard.stringArray(forKey: reactionsKey()) ?? []
        reactedIds = Set(stored.compactMap { UUID(uuidString: $0) })
    }

    private func toggleReaction(messageId: UUID) {
        if reactedIds.contains(messageId) {
            reactedIds.remove(messageId)
        } else {
            reactedIds.insert(messageId)
        }
        UserDefaults.standard.set(Array(reactedIds).map(\.uuidString), forKey: reactionsKey())
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

private struct WingmanBar: View {
    let response: WingmanRouterResponse?
    let isLoading: Bool
    var waitingForReply: Bool = false
    let onTap: (String) -> Void
    var onGenerateMore: (() -> Void)? = nil

    private struct VariantStyle {
        let label: String
        let emoji: String
        let color: Color
    }

    private let variantStyles: [String: VariantStyle] = [
        "safe":    VariantStyle(label: "Safe",    emoji: "🟢", color: Color(.systemGreen)),
        "playful": VariantStyle(label: "Playful", emoji: "😄", color: chatBrand),
        "bold":    VariantStyle(label: "Bold",    emoji: "🔥", color: Color(.systemOrange)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if waitingForReply {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Warte auf Antwort…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.systemGray6), in: Capsule())
                .frame(maxWidth: .infinity)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Wingman denkt…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.systemGray6), in: Capsule())
                .frame(maxWidth: .infinity)
            } else if let variants = response?.variants, !variants.isEmpty {
                // Header row
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(chatBrand)
                        Text("Wingman")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(chatBrand)
                        if let confidence = response?.confidence {
                            Text("· \(Int(confidence * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let onGenerateMore {
                        Button { onGenerateMore() } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                Text("-1 Credit")
                            }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Best variant highlighted
                let bestIdx = response?.bestVariantIndex ?? 0
                let bestVariant = variants[min(bestIdx, variants.count - 1)]
                let bestStyle = variantStyles[bestVariant.label] ?? VariantStyle(label: bestVariant.label, emoji: "✨", color: chatBrand)

                Button { onTap(bestVariant.text) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text(bestStyle.emoji).font(.caption)
                                Text(bestStyle.label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(bestStyle.color)
                                Text("· Empfohlen")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(bestVariant.text)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(bestStyle.color)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(bestStyle.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(bestStyle.color.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Other variants as compact chips
                let otherVariants = variants.enumerated().filter { $0.offset != bestIdx }
                if !otherVariants.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(otherVariants, id: \.element.id) { _, v in
                            let style = variantStyles[v.label] ?? VariantStyle(label: v.label, emoji: "💬", color: .secondary)
                            Button { onTap(v.text) } label: {
                                HStack(spacing: 5) {
                                    Text(style.emoji).font(.caption)
                                    Text(style.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(style.color)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(style.color.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }

                // Risk flags (if any)
                if let flags = response?.riskFlags, !flags.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Text(flags.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
}

private struct MessageBubble: View {
    let text: String
    let isMine: Bool
    let timestamp: Date
    let status: ChatViewModel.SendStatus
    var isLastRead: Bool = false
    var isReacted: Bool = false
    var onImageTap: ((URL) -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onReact: (() -> Void)? = nil

    private var isImage: Bool { text.hasPrefix("[IMG]") }
    private var imageURL: URL? {
        guard isImage else { return nil }
        return URL(string: String(text.dropFirst(5)))
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if isMine { Spacer(minLength: 60) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if let url = imageURL {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                                .frame(maxWidth: 220, maxHeight: 260)
                                .clipped()
                        case .empty:
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.systemGray5))
                                    .frame(width: 180, height: 180)
                                ProgressView()
                            }
                        case .failure:
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.systemGray5))
                                    .frame(width: 180, height: 180)
                                VStack(spacing: 6) {
                                    Image(systemName: "photo")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("Bild nicht verfügbar")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { onImageTap?(url) }
                } else {
                    Text(text)
                        .font(.body)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .foregroundStyle(isMine ? .white : .primary)
                        .background(
                            isMine
                                ? AnyShapeStyle(LinearGradient(colors: [chatBrand, chatBrandAlt], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color(.systemGray4))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: isMine ? chatBrand.opacity(0.25) : .black.opacity(0.1), radius: 6, y: 2)
                        .overlay(alignment: isMine ? .bottomLeading : .bottomTrailing) {
                            if isReacted {
                                Text("❤️")
                                    .font(.system(size: 14))
                                    .padding(3)
                                    .background(Color(.systemBackground), in: Circle())
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                                    .offset(x: isMine ? -4 : 4, y: 10)
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                        .gesture(TapGesture(count: 2).onEnded { onReact?() })
                }

                HStack(spacing: 4) {
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                    if isMine {
                        switch status {
                        case .sending: Text("Sende…")
                        case .failed(let errMsg):
                            Text("Fehler: \(errMsg)").foregroundStyle(.red)
                            if let onRetry {
                                Button(action: onRetry) {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        case .sent: EmptyView()
                        }
                    }
                    if isLastRead {
                        Text("Gelesen").foregroundStyle(chatBrand)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if !isMine { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Typing indicators

private struct TypingDotsView: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .scaleEffect(phase == i ? 1.4 : 0.8)
                    .animation(.easeInOut(duration: 0.35), value: phase)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

private struct TypingBubble: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .scaleEffect(phase == i ? 1.3 : 0.85)
                        .offset(y: phase == i ? -3 : 0)
                        .animation(.easeInOut(duration: 0.35), value: phase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            Spacer(minLength: 60)
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - Fullscreen image viewer

private struct FullscreenImageItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ChatDateSeparator: View {
    let date: Date

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Heute" }
        if cal.isDateInYesterday(date) { return "Gestern" }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color(.systemGray4)).frame(height: 0.5)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.systemGray6), in: Capsule())
            Rectangle().fill(Color(.systemGray4)).frame(height: 0.5)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

private struct FullscreenImageView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = max(1, $0) }
                                .onEnded { _ in withAnimation(.spring()) { if scale < 1.2 { scale = 1; offset = .zero } } }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { if scale == 1 { offset = $0.translation } }
                                .onEnded { v in
                                    if scale == 1 && abs(v.translation.height) > 80 { dismiss() }
                                    else { withAnimation(.spring()) { offset = .zero } }
                                }
                        )
                default:
                    ProgressView().tint(.white)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(20)
            }
            .accessibilityLabel("Schließen")
        }
    }
}
