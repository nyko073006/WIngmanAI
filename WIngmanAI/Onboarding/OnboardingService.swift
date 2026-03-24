//
//  OnboardingService.swift
//  WIngmanAI
//
//  Created by Nyko on 31.01.26.
//

import Foundation
import Supabase

final class OnboardingService {
    private var client: SupabaseClient { SupabaseManager.shared.client }

    func fetchOnboardingComplete(userId: UUID) async throws -> Bool {
        struct Row: Decodable { let onboarding_complete: Bool }

        let res = try await client.database
            .from("profiles")
            .select("onboarding_complete")
            .eq("id", value: userId.uuidString)
            .single()
            .execute()

        let row = try JSONDecoder().decode(Row.self, from: res.data)
        return row.onboarding_complete
    }

    func setOnboardingComplete(userId: UUID, value: Bool) async throws {
        struct Patch: Encodable { let onboarding_complete: Bool }

        _ = try await client.database
            .from("profiles")
            .update(Patch(onboarding_complete: value))
            .eq("id", value: userId.uuidString)
            .execute()
    }
}
