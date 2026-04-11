//
//  ChatViewModel.swift
//  WingmanAI
//
//  Created by Nyko on 12.02.26.
//

import Foundation
import Combine
import Supabase
import UIKit
import Network

@MainActor
final class ChatViewModel: ObservableObject {

    enum SendStatus: Equatable {
        case sent
        case sending
        case failed(String)
    }

    struct Message: Identifiable, Equatable {
        let id: UUID
        let senderId: UUID
        let text: String
        let createdAt: Date
        var status: SendStatus = .sent
    }

    @Published var isLoading: Bool = false
    @Published var isLoadingMore: Bool = false
    @Published var hasMore: Bool = true

    @Published var isSending: Bool = false
    @Published var isUploadingImage: Bool = false
    @Published var isOffline: Bool = false
    @Published var errorText: String? = nil
    @Published var messages: [Message] = []
    @Published var otherLastSeenAt: Date? = nil
    @Published var wingmanResponse: WingmanRouterResponse? = nil
    @Published var isLoadingWingSuggestions: Bool = false

    var wingSuggestions: [String] {
        wingmanResponse?.variants?.map { $0.text } ?? []
    }

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    private struct MessageRow: Decodable {
        let id: UUID
        let sender_id: UUID
        let text: String
        let created_at: Date
        let match_id: UUID
    }

    private struct MessageInsert: Encodable {
        let match_id: UUID
        let sender_id: UUID
        let text: String
    }

    // MARK: - Realtime

    private var channel: RealtimeChannelV2?
    private var streamTask: Task<Void, Never>?
    private var currentMatchId: UUID?

    // MARK: - Step 4 Read receipts (DB)
    private var myUserId: UUID?

    // MARK: - Offline Queue

    private struct QueuedMessage: Codable {
        let matchId: UUID
        let senderId: UUID
        let text: String
        let tempId: UUID
    }

    private var networkMonitor: NWPathMonitor?
    private var offlineQueueKey: String { "offline_msg_queue_\(myUserId?.uuidString ?? "guest")" }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isOffline = path.status != .satisfied
                if path.status == .satisfied {
                    self?.retryOfflineQueue()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "nw.monitor"))
    }

    private func enqueueOffline(matchId: UUID, senderId: UUID, text: String, tempId: UUID) {
        var queue = loadOfflineQueue()
        queue.append(QueuedMessage(matchId: matchId, senderId: senderId, text: text, tempId: tempId))
        saveOfflineQueue(queue)
    }

    private func retryOfflineQueue() {
        let queue = loadOfflineQueue()
        guard !queue.isEmpty else { return }
        saveOfflineQueue([])
        for item in queue {
            Task { await self.send(matchId: item.matchId, senderId: item.senderId, text: item.text) }
        }
    }

    private func loadOfflineQueue() -> [QueuedMessage] {
        guard let data = UserDefaults.standard.data(forKey: offlineQueueKey),
              let decoded = try? JSONDecoder().decode([QueuedMessage].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveOfflineQueue(_ queue: [QueuedMessage]) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        UserDefaults.standard.set(data, forKey: offlineQueueKey)
    }

    // MARK: - Step 5 Typing

    @Published var otherIsTyping: Bool = false

    private var typingOffTask: Task<Void, Never>?
    private var typingTimeoutTask: Task<Void, Never>?
    private var lastTypingSentAt: Date = .distantPast

    /// Call from ChatView on each draft change.
    func userDidType(matchId: UUID) {
        // Only send typing for the currently active match channel
        guard currentMatchId == matchId else { return }
        guard let ch = channel else { return }
        guard let uid = myUserId else { return }

        // Throttle to avoid spamming
        let now = Date()
        if now.timeIntervalSince(lastTypingSentAt) < 0.35 { return }
        lastTypingSentAt = now

        // Send typing=true (fire-and-forget)
        Task {
            try? await ch.broadcast(event: "typing", message: [
                "user_id": uid.uuidString,
                "match_id": matchId.uuidString,
                "typing": "true"
            ])
        }

        // Schedule typing=false after idle
        typingOffTask?.cancel()
        typingOffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            await self.sendTypingOff(matchId: matchId)
        }
    }

    /// Call once from ChatView (onAppear) so the VM can write match_reads.
    func setMyUserId(_ id: UUID) {
        self.myUserId = id
        startNetworkMonitor()
    }

    private func sendTypingOff(matchId: UUID) async {
        guard currentMatchId == matchId else { return }
        guard let ch = channel else { return }
        guard let uid = myUserId else { return }
        try? await ch.broadcast(event: "typing", message: [
            "user_id": uid.uuidString,
            "match_id": matchId.uuidString,
            "typing": "false"
        ])
    }

    private func startTypingListener(matchId: UUID) {
        guard let ch = channel else { return }
        let myUid = myUserId?.uuidString

        let stream = ch.broadcastStream(event: "typing")
        Task { [weak self] in
            guard let self else { return }

            func str(_ v: AnyJSON?) -> String? {
                if case let .string(s) = v { return s }
                return nil
            }

            for await raw in stream {
                // Some SDK versions deliver the user payload directly, others wrap it as {"payload": {...}}.
                var payload = raw
                if case let .object(inner)? = raw["payload"] {
                    payload = inner
                }

                let sender = str(payload["user_id"]) ?? ""
                if sender.isEmpty { continue }
                if let myUid, sender == myUid { continue }

                guard str(payload["match_id"]) == matchId.uuidString else { continue }

                let typingStr = str(payload["typing"]) ?? "false"
                let isTyping = (typingStr == "true")

                await MainActor.run {
                    self.otherIsTyping = isTyping
                    // Auto-timeout: clear after 3s in case typing=false is never sent
                    self.typingTimeoutTask?.cancel()
                    if isTyping {
                        self.typingTimeoutTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            guard let self, !Task.isCancelled else { return }
                            await MainActor.run { self.otherIsTyping = false }
                        }
                    }
                }
            }
        }
    }

    private struct MatchReadUpsert: Encodable {
        let match_id: UUID
        let user_id: UUID
        let last_seen_at: Date
    }

    private func upsertLastSeen(matchId: UUID) async {
        guard let uid = myUserId else { return }
        do {
            let payload: [String: String] = [
                "match_id": matchId.uuidString,
                "user_id": uid.uuidString,
                "last_seen_at": ISO8601DateFormatter().string(from: Date())
            ]
            
            _ = try await client
                .from("match_reads")
                .upsert(
                    payload,
                    onConflict: "match_id,user_id"
                )
                .execute()
        } catch {
            // silent — read receipts are non-critical
        }
    }

    private var oldestCursor: Date? = nil
    private let pageSize: Int = 60

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)

            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]

            if let dt = f1.date(from: s) ?? f2.date(from: s) { return dt }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        }
        return d
    }()

    func startRealtime(matchId: UUID) async {
        if currentMatchId == matchId, channel != nil, streamTask != nil { return }

        await stopRealtime()
        currentMatchId = matchId

        let uniqueChannelName = "chat-\(matchId.uuidString)-\(UUID().uuidString)"
        let ch = client.realtimeV2.channel(uniqueChannelName)
        channel = ch

        let stream = ch.postgresChange(
            Realtime.InsertAction.self,
            schema: "public",
            table: "messages",
            filter: .eq("match_id", value: matchId.uuidString)
        )

        streamTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await ch.subscribeWithError()
                await self.upsertLastSeen(matchId: matchId)
                self.startTypingListener(matchId: matchId)
            } catch {
                return
            }

            do {
                for await insert in stream {
                    let row = try insert.decodeRecord(as: MessageRow.self, decoder: Self.decoder)

                    let msg = Message(
                        id: row.id,
                        senderId: row.sender_id,
                        text: row.text,
                        createdAt: row.created_at,
                        status: .sent
                    )

                    if let idx = self.messages.firstIndex(where: {
                        $0.status != .sent &&
                        $0.senderId == msg.senderId &&
                        $0.text == msg.text &&
                        abs($0.createdAt.timeIntervalSince(msg.createdAt)) < 2
                    }) {
                        self.messages[idx] = msg
                    } else if !self.messages.contains(where: { $0.id == msg.id }) {
                        self.messages.append(msg)
                    }

                    self.messages.sort { $0.createdAt < $1.createdAt }
                    self.oldestCursor = self.messages.first?.createdAt

                    await self.upsertLastSeen(matchId: matchId)
                    await self.fetchOtherLastSeen(matchId: matchId)
                }
            } catch {
                if Task.isCancelled { return }
            }

            // Stream ended — reconnect after 2s
            guard !Task.isCancelled else { return }
            await client.realtimeV2.removeChannel(ch)
            self.channel = nil
            self.streamTask = nil
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.currentMatchId == matchId else { return }
                await self.startRealtime(matchId: matchId)
            }
        }
    }

    func fetchOtherLastSeen(matchId: UUID) async {
        guard let myId = myUserId else { return }
        struct Row: Decodable { let user_id: UUID; let last_seen_at: Date }
        guard let response = try? await client
            .from("match_reads")
            .select("user_id,last_seen_at")
            .eq("match_id", value: matchId.uuidString)
            .execute() else { return }
        guard let rows = try? Self.decoder.decode([Row].self, from: response.data) else { return }
        if let other = rows.first(where: { $0.user_id != myId }) {
            self.otherLastSeenAt = other.last_seen_at
        }
    }

    func sendImage(matchId: UUID, senderId: UUID, imageData: Data) async {
        let compressed = compressImage(imageData) ?? imageData

        isUploadingImage = true
        defer { isUploadingImage = false }

        let bucket = "message-photos"
        let path = "\(matchId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let accessToken = (try? await SupabaseClientProvider.shared.client.auth.session.accessToken) ?? ""

        do {
            let url = SupabaseClientProvider.shared.supabaseURL
                .appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = compressed
            req.setValue(SupabaseClientProvider.shared.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            req.setValue("true", forHTTPHeaderField: "x-upsert")
            let (uploadData, uploadResp) = try await URLSession.shared.data(for: req)
            if let http = uploadResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: uploadData, encoding: .utf8) ?? ""
                throw NSError(domain: "StorageUpload", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Upload fehlgeschlagen (\(http.statusCode)). \(body)"])
            }

            let publicUrl = try SupabaseClientProvider.shared.client.storage
                .from(bucket).getPublicURL(path: path).absoluteString
            await send(matchId: matchId, senderId: senderId, text: "[IMG]\(publicUrl)")
        } catch {
            self.errorText = "Bild konnte nicht gesendet werden. \(AppError.userMessage(for: error))"
        }
    }

    private func compressImage(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1200
        let scale = min(1.0, maxSide / max(img.size.width, img.size.height))
        guard scale < 1.0 else { return img.jpegData(compressionQuality: 0.8) }
        let newSize = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.8)
    }

    func stopRealtime() async {
        streamTask?.cancel()
        streamTask = nil

        let mid = currentMatchId
        let ch = channel
        // Capture before nil so typing-off can still be sent
        channel = nil
        currentMatchId = nil

        typingOffTask?.cancel()
        typingOffTask = nil
        typingTimeoutTask?.cancel()
        typingTimeoutTask = nil
        otherIsTyping = false

        // Send typing=false using the captured channel before removal
        if let mid, let ch {
            try? await ch.broadcast(event: "typing", message: [
                "user_id": myUserId?.uuidString ?? "",
                "match_id": mid.uuidString,
                "typing": "false"
            ])
        }

        if let ch { await client.realtimeV2.removeChannel(ch) }
    }

    // MARK: - Wingman AI

    func loadWingSuggestions(matchId: UUID, otherName: String) async {
        guard !isLoadingWingSuggestions else { return }
        guard let myId = myUserId else { return }
        isLoadingWingSuggestions = true
        wingmanResponse = nil
        defer { isLoadingWingSuggestions = false }

        // Derive other user ID
        struct MatchRow: Decodable { let user_low: UUID; let user_high: UUID }
        let otherUserId: UUID
        do {
            let match: MatchRow = try await client
                .from("matches")
                .select("user_low,user_high")
                .eq("id", value: matchId.uuidString)
                .single()
                .execute()
                .value
            otherUserId = (match.user_low == myId) ? match.user_high : match.user_low
        } catch {
            self.errorText = "Wingman konnte nicht gestartet werden. \(AppError.userMessage(for: error))"
            return
        }

        // Fetch match profile
        struct ProfileRow: Decodable {
            let bio: String?
            let interests: [String]?
            let display_name: String?
            let birthdate: String?
            let city: String?
        }
        let profile: ProfileRow? = try? await client
            .from("profiles")
            .select("bio,interests,display_name,birthdate,city")
            .eq("user_id", value: otherUserId.uuidString)
            .single()
            .execute()
            .value

        let matchProfile = WingmanMatchProfile(
            name: profile?.display_name ?? otherName,
            bio: profile?.bio,
            interests: profile?.interests ?? [],
            city: profile?.city
        )

        // Build chat history (last 15 non-image messages)
        let chatHistory = messages.suffix(15)
            .filter { !$0.text.hasPrefix("[IMG]") }
            .map { WingmanMessage(role: $0.senderId == myId ? "me" : "them", text: $0.text) }

        do {
            let response = try await AIService.shared.suggestMessage(
                conversationId: matchId.uuidString,
                chatHistory: chatHistory,
                matchProfile: matchProfile,
                screenContext: "chat"
            )
            self.wingmanResponse = response
            AnalyticsService.shared.track(.wingmanUsed, properties: ["match_id": matchId.uuidString])
        } catch {
            self.errorText = "Wingman konnte keine Vorschläge laden. \(AppError.userMessage(for: error))"
        }
    }

    // MARK: - Load / Send

    func loadInitial(matchId: UUID) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let rows: [MessageRow] = try await client
                .from("messages")
                .select("id,sender_id,text,created_at,match_id")
                .eq("match_id", value: matchId.uuidString)
                .order("created_at", ascending: false)
                .limit(pageSize)
                .execute()
                .value

            let mapped = rows.map {
                Message(id: $0.id, senderId: $0.sender_id, text: $0.text, createdAt: $0.created_at, status: .sent)
            }.sorted { $0.createdAt < $1.createdAt }

            self.messages = mapped
            self.oldestCursor = mapped.first?.createdAt
            self.hasMore = rows.count >= pageSize

            await upsertLastSeen(matchId: matchId)
            await fetchOtherLastSeen(matchId: matchId)
        } catch {
            self.errorText = "Nachrichten konnten nicht geladen werden. \(AppError.userMessage(for: error))"
            self.messages = []
            self.hasMore = false
        }
    }

    func loadMore(matchId: UUID) async {
        guard hasMore else { return }
        guard !isLoadingMore else { return }
        guard let cursor = oldestCursor else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let rows: [MessageRow] = try await client
                .from("messages")
                .select("id,sender_id,text,created_at,match_id")
                .eq("match_id", value: matchId.uuidString)
                .lt("created_at", value: cursor)
                .order("created_at", ascending: false)
                .limit(pageSize)
                .execute()
                .value

            if rows.isEmpty { hasMore = false; return }

            let mapped = rows.map {
                Message(id: $0.id, senderId: $0.sender_id, text: $0.text, createdAt: $0.created_at, status: .sent)
            }.sorted { $0.createdAt < $1.createdAt }

            let existing = Set(messages.map { $0.id })
            let newOnes = mapped.filter { !existing.contains($0.id) }

            self.messages = newOnes + self.messages
            self.oldestCursor = self.messages.first?.createdAt
            self.hasMore = rows.count >= pageSize
        } catch {
            if Task.isCancelled || (error is CancellationError) { return }
            self.errorText = AppError.userMessage(for: error)
        }
    }

    func retry(messageId: UUID, matchId: UUID) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              case .failed = messages[idx].status,
              let senderId = myUserId else { return }

        let text = messages[idx].text
        messages[idx].status = .sending

        do {
            let payload: [String: String] = [
                "match_id": matchId.uuidString,
                "sender_id": senderId.uuidString,
                "text": text
            ]
            let inserted: MessageRow = try await client
                .from("messages")
                .insert([payload]) // Force JSON Array enclosure!
                .select("id,sender_id,text,created_at,match_id")
                .single()
                .execute()
                .value

            let final = Message(
                id: inserted.id,
                senderId: inserted.sender_id,
                text: inserted.text,
                createdAt: inserted.created_at,
                status: .sent
            )
            if let cur = self.messages.firstIndex(where: { $0.id == messageId }) {
                self.messages[cur] = final
            }
            self.messages.sort { $0.createdAt < $1.createdAt }
        } catch {
            if let cur = self.messages.firstIndex(where: { $0.id == messageId }) {
                self.messages[cur].status = .failed(AppError.userMessage(for: error))
            }
        }
    }

    func send(matchId: UUID, senderId: UUID, text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        isSending = true
        errorText = nil

        if myUserId == nil { myUserId = senderId }

        let tempId = UUID()
        let now = Date()

        let optimistic = Message(id: tempId, senderId: senderId, text: clean, createdAt: now, status: .sending)
        self.messages.append(optimistic)
        self.messages.sort { $0.createdAt < $1.createdAt }

        defer { isSending = false }

        do {
            let payload: [String: String] = [
                "match_id": matchId.uuidString,
                "sender_id": senderId.uuidString,
                "text": clean
            ]
            let inserted: MessageRow = try await client
                .from("messages")
                .insert([payload]) // Force JSON Array enclosure!
                .select("id,sender_id,text,created_at,match_id")
                .single()
                .execute()
                .value

            let final = Message(
                id: inserted.id,
                senderId: inserted.sender_id,
                text: inserted.text,
                createdAt: inserted.created_at,
                status: .sent
            )

            if let idx = self.messages.firstIndex(where: { $0.id == tempId }) {
                self.messages[idx] = final
            } else if !self.messages.contains(where: { $0.id == final.id }) {
                self.messages.append(final)
            }

            self.messages.sort { $0.createdAt < $1.createdAt }
            self.oldestCursor = self.messages.first?.createdAt

            AnalyticsService.shared.track(.messageSent, properties: ["match_id": matchId.uuidString])
            await upsertLastSeen(matchId: matchId)
        } catch {
            // Queue for offline retry if it looks like a network error
            let isNetworkError = (error as? URLError)?.code == .notConnectedToInternet
                || (error as? URLError)?.code == .networkConnectionLost
                || (error as? URLError)?.code == .timedOut
            if isNetworkError {
                enqueueOffline(matchId: matchId, senderId: senderId, text: clean, tempId: tempId)
                if let idx = self.messages.firstIndex(where: { $0.id == tempId }) {
                    self.messages[idx].status = .failed("Offline – wird gesendet sobald Verbindung besteht")
                }
            } else if let idx = self.messages.firstIndex(where: { $0.id == tempId }) {
                self.messages[idx].status = .failed(AppError.userMessage(for: error))
            }
        }
    }

    deinit {
        networkMonitor?.cancel()
    }
}
