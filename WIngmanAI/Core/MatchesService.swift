//
//  MatchesService.swift
//  WingmanAI
//
//  Created by Nyko on 11.02.26.
//

import Foundation
import Supabase

@MainActor
final class MatchesService {
    static let shared = MatchesService()
    private init() {}

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    struct MatchRow: Decodable, Identifiable {
        let id: UUID
        let user_low: UUID
        let user_high: UUID
        let created_at: Date
        let last_message_at: Date?

        func otherUserId(myId: UUID) -> UUID {
            return (user_low == myId) ? user_high : user_low
        }
    }

    func fetchMyMatches(myId: UUID) async throws -> [MatchRow] {
        let rows: [MatchRow] = try await client
            .from("matches")
            .select("id,user_low,user_high,created_at,last_message_at")
            .or("user_low.eq.\(myId.uuidString),user_high.eq.\(myId.uuidString)")
            .order("last_message_at", ascending: false, nullsFirst: false)
            .order("created_at", ascending: false)
            .limit(200)
            .execute()
            .value

        return rows
    }
}
