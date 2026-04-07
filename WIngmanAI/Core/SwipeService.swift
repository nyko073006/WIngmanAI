//
//  SwipeService.swift
//  WingmanAI
//
//  Created by Nyko on 09.02.26.
//
import Foundation
import Supabase

final class SwipeService {
    static let shared = SwipeService()
    private init() {}

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    struct SwipeUpsert: Encodable {
        let swiper_id: UUID
        let target_id: UUID
        let is_like: Bool
    }

    struct SwipeUpsertWithMessage: Encodable {
        let swiper_id: UUID
        let target_id: UUID
        let is_like: Bool
        let intro_message: String
    }

    func upsertSwipe(swiperId: UUID, targetId: UUID, isLike: Bool) async throws {
        let payload = SwipeUpsert(swiper_id: swiperId, target_id: targetId, is_like: isLike)
        _ = try await client
            .from("swipes")
            .upsert(payload, onConflict: "swiper_id,target_id")
            .execute()
    }

    func upsertSwipeWithMessage(swiperId: UUID, targetId: UUID, message: String) async throws {
        let payload = SwipeUpsertWithMessage(swiper_id: swiperId, target_id: targetId, is_like: true, intro_message: message)
        _ = try await client
            .from("swipes")
            .upsert(payload, onConflict: "swiper_id,target_id")
            .execute()
    }

    /// Returns the match id if a mutual match already exists, else nil.
    func matchIdIfExists(myUserId: UUID, otherUserId: UUID) async -> UUID? {
        let low = min(myUserId, otherUserId)
        let high = max(myUserId, otherUserId)
        struct Row: Decodable { let id: UUID }
        do {
            let rows: [Row] = try await client
                .from("matches")
                .select("id")
                .eq("user_low", value: low.uuidString)
                .eq("user_high", value: high.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first?.id
        } catch { return nil }
    }

    /// Sends a message into a match (used after a match is confirmed).
    func sendMessage(matchId: UUID, senderId: UUID, text: String) async throws {
        let payload: [String: String] = [
            "match_id": matchId.uuidString,
            "sender_id": senderId.uuidString,
            "text": text
        ]
        _ = try await client
            .from("messages")
            .insert([payload])
            .execute()
    }

    func fetchSwipedTargetIds(swiperId: UUID) async throws -> Set<UUID> {
        struct Row: Decodable { let target_id: UUID }

        let rows: [Row] = try await client
            .from("swipes")
            .select("target_id")
            .eq("swiper_id", value: swiperId.uuidString)
            .execute()
            .value

        return Set(rows.map { $0.target_id })
    }

    func deleteSwipe(swiperId: UUID, targetId: UUID) async throws {
        _ = try await client
            .from("swipes")
            .delete()
            .eq("swiper_id", value: swiperId.uuidString)
            .eq("target_id", value: targetId.uuidString)
            .execute()
    }

    // MARK: - Block & Report

    func block(blockerId: UUID, blockedId: UUID) async throws {
        struct BlockInsert: Encodable { let blocker_id: UUID; let blocked_id: UUID }
        _ = try await client
            .from("blocks")
            .upsert(BlockInsert(blocker_id: blockerId, blocked_id: blockedId), onConflict: "blocker_id,blocked_id")
            .execute()
    }

    func report(reporterId: UUID, reportedId: UUID, reason: String) async throws {
        struct ReportInsert: Encodable { let reporter_id: UUID; let target_user_id: UUID; let reason: String }
        _ = try await client
            .from("reports")
            .insert(ReportInsert(reporter_id: reporterId, target_user_id: reportedId, reason: normalizeReportReason(reason)))
            .execute()
    }

    /// Maps German UI labels → DB enum values
    private func normalizeReportReason(_ reason: String) -> String {
        switch reason {
        case "Spam":                  return "spam"
        case "Belästigung":           return "harassment"
        case "Fake-Profil":           return "fake"
        case "Unangemessene Fotos":   return "scam"
        case "Minderjährig":          return "underage"
        default:                      return "other"
        }
    }
}
