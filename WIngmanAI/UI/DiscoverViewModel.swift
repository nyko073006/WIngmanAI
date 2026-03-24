//
//  DiscoverViewModel.swift
//  WingmanAI
//
//  Created by Nyko on 09.02.26.
//

import Foundation
import Combine
import Supabase

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorText: String?

    @Published var profiles: [PublicProfile] = []
    @Published var currentIndex: Int = 0
    @Published var showMatchAlert = false

    private let swipeService = SwipeService.shared
    private let matchService = MatchService.shared

    func load(myUserId: UUID) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let swiped = try await swipeService.fetchSwipedTargetIds(swiperId: myUserId)
            let blocked = try await fetchBlockedUserIds(myUserId: myUserId)
            let matched = try await fetchMatchedUserIds(myUserId: myUserId)

            let excluded = swiped.union(blocked).union(matched).union([myUserId])

            let fetched: [PublicProfile] = try await SupabaseClientProvider.shared.client
                .from("profiles")
                .select("user_id,display_name,city,bio,interests,birthdate")
                .eq("is_active", value: true)
                .eq("discovery_enabled", value: true)
                .or("onboarding_complete.eq.true,is_onboarded.eq.true")
                .limit(80)
                .execute()
                .value

            self.profiles = fetched.filter { !excluded.contains($0.id) }
            self.currentIndex = 0
        } catch {
            self.errorText = error.localizedDescription
        }
    }

    func swipe(myUserId: UUID, isLike: Bool) async {
        guard currentIndex < profiles.count else { return }
        let target = profiles[currentIndex]

        do {
            try await swipeService.upsertSwipe(swiperId: myUserId, targetId: target.id, isLike: isLike)

            if isLike, await matchService.createMatchWith(targetId: target.id) {
                showMatchAlert = true
            }

            currentIndex += 1
        } catch {
            errorText = error.localizedDescription
        }
    }

    var currentProfile: PublicProfile? {
        guard currentIndex < profiles.count else { return nil }
        return profiles[currentIndex]
    }

    private func fetchBlockedUserIds(myUserId: UUID) async throws -> Set<UUID> {
        struct Row: Decodable { let blocker_id: UUID; let blocked_id: UUID }

        let blockedByMe: [Row] = try await SupabaseClientProvider.shared.client
            .from("blocks")
            .select("blocker_id,blocked_id")
            .eq("blocker_id", value: myUserId.uuidString)
            .execute()
            .value

        let blockedMe: [Row] = try await SupabaseClientProvider.shared.client
            .from("blocks")
            .select("blocker_id,blocked_id")
            .eq("blocked_id", value: myUserId.uuidString)
            .execute()
            .value

        var out = Set<UUID>()
        out.formUnion(blockedByMe.map { $0.blocked_id })
        out.formUnion(blockedMe.map { $0.blocker_id })
        return out
    }

    private func fetchMatchedUserIds(myUserId: UUID) async throws -> Set<UUID> {
        struct Row: Decodable { let user_low: UUID; let user_high: UUID }

        let rows: [Row] = try await SupabaseClientProvider.shared.client
            .from("matches")
            .select("user_low,user_high")
            .or("user_low.eq.\(myUserId.uuidString),user_high.eq.\(myUserId.uuidString)")
            .limit(200)
            .execute()
            .value

        var out = Set<UUID>()
        for r in rows {
            if r.user_low == myUserId { out.insert(r.user_high) }
            else if r.user_high == myUserId { out.insert(r.user_low) }
        }
        return out
    }
}
