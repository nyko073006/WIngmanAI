//
//  MatchesViewModel.swift
//  WingmanAI
//
//  Created by Nyko on 11.02.26.
//

import Foundation
import Combine
import Supabase

@MainActor
final class MatchesViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var items: [MatchItem] = []

    struct MatchItem: Identifiable, Codable, Equatable {
        let id: UUID
        let otherUserId: UUID
        let name: String
        let photoUrl: String?
        let lastMessageAt: Date?
        let lastMessageText: String?
        let subtitle: String?
        let unreadCount: Int
    }

    func load(myId: UUID) async {
        if items.isEmpty {
            if let data = UserDefaults.standard.data(forKey: "matches_cache_\(myId.uuidString)"),
               let cached = try? JSONDecoder().decode([MatchItem].self, from: data) {
                self.items = cached
            }
        }
        
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let matches = try await MatchesService.shared.fetchMyMatches(myId: myId)
            let otherIds = matches.map { $0.otherUserId(myId: myId) }

            guard !otherIds.isEmpty else {
                self.items = []
                return
            }

            struct ProfileLite: Decodable, Sendable { let user_id: UUID; let display_name: String }
            struct PhotoLite: Decodable, Sendable { let user_id: UUID; let url: String }
            struct LastMsgRow: Decodable, Sendable { let match_id: UUID; let text: String; let created_at: Date; let sender_id: UUID }
            struct UnreadRow: Decodable, Sendable {
                let match_id: UUID
                let unread_count: Int
                let last_seen_at: Date?
            }

            let matchIdsStr = matches.map { $0.id.uuidString }
            let matchIdsUUID = matches.map { $0.id }
            let otherIdsStr = otherIds.map { $0.uuidString }
            let client = SupabaseClientProvider.shared.client

            async let profilesTask: [ProfileLite] = client
                .from("profiles")
                .select("user_id,display_name")
                .in("user_id", values: otherIdsStr)
                .execute()
                .value

            async let photosTask: [PhotoLite] = client
                .from("photos")
                .select("user_id,url")
                .in("user_id", values: otherIdsStr)
                .eq("is_primary", value: true)
                .eq("is_snapshot", value: false)
                .execute()
                .value

            async let lastRowsTask: [LastMsgRow] = client
                .from("messages")
                .select("match_id,text,created_at,sender_id")
                .in("match_id", values: matchIdsStr)
                .order("created_at", ascending: false)
                .limit(400)
                .execute()
                .value

            async let unreadRowsTask: [UnreadRow] = client
                .rpc("get_unread_counts", params: ["p_match_ids": matchIdsUUID])
                .execute()
                .value

            let (profiles, photos, lastRows, unreadRows) = try await (profilesTask, photosTask, lastRowsTask, unreadRowsTask)

            var nameById: [UUID: String] = [:]
            for p in profiles {
                let n = p.display_name.trimmingCharacters(in: .whitespacesAndNewlines)
                nameById[p.user_id] = n.isEmpty ? "Unbekannt" : n
            }

            var photoById: [UUID: String] = [:]
            for ph in photos { photoById[ph.user_id] = ph.url }

            var lastByMatch: [UUID: LastMsgRow] = [:]
            for r in lastRows where lastByMatch[r.match_id] == nil { lastByMatch[r.match_id] = r }

            var unreadByMatch: [UUID: Int] = [:]
            unreadByMatch.reserveCapacity(unreadRows.count)
            for r in unreadRows {
                unreadByMatch[r.match_id] = r.unread_count
            }

            var built: [MatchItem] = []
            built.reserveCapacity(matches.count)

            for m in matches {
                let otherId = m.otherUserId(myId: myId)
                let name = nameById[otherId] ?? "Unbekannt"

                let lastMsg = lastByMatch[m.id]
                let lastAt = lastMsg?.created_at ?? m.last_message_at

                let rawText = lastMsg?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isImg = rawText.hasPrefix("[IMG]")
                let displayText = isImg ? "📷 Foto" : rawText
                let isMine = lastMsg?.sender_id == myId
                let subtitle: String? = displayText.isEmpty ? nil : (isMine ? "Du: \(displayText)" : displayText)

                let unread = unreadByMatch[m.id] ?? 0

                built.append(
                    MatchItem(
                        id: m.id,
                        otherUserId: otherId,
                        name: name,
                        photoUrl: photoById[otherId],
                        lastMessageAt: lastAt,
                        lastMessageText: displayText.isEmpty ? nil : displayText,
                        subtitle: subtitle,
                        unreadCount: unread
                    )
                )
            }

            built.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
            if self.items != built {
                self.items = built
                if let data = try? JSONEncoder().encode(built) {
                    UserDefaults.standard.set(data, forKey: "matches_cache_\(myId.uuidString)")
                }
            }
        } catch {
            if Task.isCancelled || (error is CancellationError) { return }
            // Only clear items if it's currently empty to preserve offline cache
            if self.items.isEmpty { self.items = [] }
            self.errorText = error.localizedDescription
        }
    }
}
