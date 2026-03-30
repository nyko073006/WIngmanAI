//
//  MatchService.swift
//  WingmanAI
//
//  Created by Nyko on 09.02.26.
//

import Foundation
import Supabase

final class MatchService {
    static let shared = MatchService()
    private init() {}

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    /// Calls RPC `create_match_with(target uuid)` -> returns true if a new match was created.
    /// Handles potential errors from the Supabase SDK by returning `false` on failure.
    func createMatchWith(targetId: UUID) async -> Bool {
        let params: [String: String] = ["target": targetId.uuidString]

        do {
            let created: Bool = try await client
                .rpc("create_match_with", params: params)
                .execute()
                .value
            return created
        } catch {
            return false
        }
    }
}

