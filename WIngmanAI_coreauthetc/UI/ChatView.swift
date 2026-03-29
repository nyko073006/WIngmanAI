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

    let matchId: UUID
    let otherName: String
    let otherUserId: UUID

    @StateObject private var vm = ChatViewModel()
    @State private var draft: String = ""
    @FocusState private var isTextFocused: Bool
    @State private var imagePickerItem: PhotosPickerItem? = nil
    @State private var fullscreenImageUrl: URL? = nil
    @StateObject private var premium = PremiumService.shared
    @State private var showSubscription = false
    @State private var reactedIds: Set<UUID> = []

    // True when the last message in the conversation was sent by us
    private var lastMessageIsFromMe: Bool {
        guard let myId = auth.session?.user.id,
              let last = vm.messages.last else { return false }
        return last.senderId == myId
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if lastMessageIsFromMe || vm.isLoadingWingSuggestions || !vm.wingSuggestions.isEmpty {
                Divider()
                WingmanBar(
                    suggestions: vm.wingSuggestions,
                    isLoading: vm.isLoadingWingSuggestions,
                    waitingForReply: lastMessageIsFromMe,
                    onTap: { s in
                        draft = s
                        vm.wingSuggestions = []
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(otherName).font(.headline)
                    if vm.otherIsTyping {
                        TypingDotsView()
                    }
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
                    
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(chatBrand)
                        Text("Noch keine Nachrichten")
                            .font(.headline)
                        Text("Sag hallo!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
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
                // iOS 17+ onChange Signature
                .onChange(of: vm.messages.last?.id) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: vm.otherIsTyping) { _, isTyping in
                    if isTyping {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
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
        guard let last = vm.messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
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
    let suggestions: [String]
    let isLoading: Bool
    var waitingForReply: Bool = false
    let onTap: (String) -> Void
    var onGenerateMore: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if waitingForReply {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Warte auf eine Antwort…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.systemGray6), in: Capsule())
            } else if isLoading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.75)
                    Text("Wingman denkt…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.systemGray6), in: Capsule())
            } else {
                ForEach(suggestions, id: \.self) { s in
                    Button { onTap(s) } label: {
                        HStack(spacing: 10) {
                            Text(s)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(chatBrand.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(chatBrand)
                    }
                    .buttonStyle(.plain)
                }
                
                if let onGenerateMore {
                    Button { onGenerateMore() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("Neue generieren")
                            Text("(-1 Credit)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(chatBrand)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .frame(maxWidth: .infinity)
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
                                Color(.systemGray5).frame(width: 180, height: 180)
                                ProgressView()
                            }
                        case .failure:
                            ZStack {
                                Color(.systemGray5).frame(width: 180, height: 60)
                                Image(systemName: "photo").foregroundStyle(.secondary)
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
                                : AnyShapeStyle(Color(.systemGray6))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: isMine ? chatBrand.opacity(0.25) : .black.opacity(0.06), radius: 6, y: 2)
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
