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

    func upsertSwipe(swiperId: UUID, targetId: UUID, isLike: Bool) async throws {
        let payload = SwipeUpsert(swiper_id: swiperId, target_id: targetId, is_like: isLike)

        _ = try await client
            .from("swipes")
            .upsert(payload, onConflict: "swiper_id,target_id")
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
        struct ReportInsert: Encodable { let reporter_id: UUID; let reported_id: UUID; let reason: String }
        _ = try await client
            .from("reports")
            .insert(ReportInsert(reporter_id: reporterId, reported_id: reportedId, reason: reason))
            .execute()
    }
}
