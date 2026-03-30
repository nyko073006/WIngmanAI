//
//  DailyRewardService.swift
//  WIngmanAI
//

import Foundation
import Combine
import Supabase

@MainActor
final class DailyRewardService: ObservableObject {
    static let shared = DailyRewardService()

    @Published private(set) var canClaimToday: Bool = false
    @Published private(set) var currentStreak: Int = 0

    private var userPrefix: String {
        guard let id = SupabaseClientProvider.shared.client.auth.currentSession?.user.id.uuidString else { return "guest_" }
        return id + "_"
    }

    private var lastClaimKey: String  { userPrefix + "daily_reward_last_claim" }
    private var streakKey: String     { userPrefix + "daily_reward_streak" }

    // MARK: - Reward Table (7-day cycle)

    struct Reward {
        let day: Int
        let aiCredits: Int
        let bonusSwipes: Int
        var isJackpot: Bool { day == 7 }
    }

    static func reward(forStreakDay day: Int) -> Reward {
        let cycleDay = ((day - 1) % 7) + 1
        
        if cycleDay == 7 {
            // Jackpot
            return Reward(
                day: cycleDay,
                aiCredits: Int.random(in: 10...25),
                bonusSwipes: Int.random(in: 20...40)
            )
        } else {
            // Base reward scales up slightly towards day 6
            let minAI = max(2, cycleDay)
            let maxAI = minAI + 4
            let minSwipes = 3 + cycleDay
            let maxSwipes = minSwipes + 7
            
            return Reward(
                day: cycleDay,
                aiCredits: Int.random(in: minAI...maxAI),
                bonusSwipes: Int.random(in: minSwipes...maxSwipes)
            )
        }
    }

    var todaysReward: Reward {
        Self.reward(forStreakDay: currentStreak + 1)
    }

    private init() { refresh() }

    func refresh() {
        let defaults = UserDefaults.standard
        let streak = defaults.integer(forKey: streakKey)
        let lastClaim = defaults.object(forKey: lastClaimKey) as? Date ?? .distantPast

        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(lastClaim)
        let isYesterday = calendar.isDateInYesterday(lastClaim)

        if isToday {
            canClaimToday = false
            currentStreak = streak
        } else if isYesterday || lastClaim == .distantPast {
            canClaimToday = true
            currentStreak = isYesterday ? streak : 0
        } else {
            // Missed more than 1 day → reset streak
            canClaimToday = true
            currentStreak = 0
        }
    }

    @discardableResult
    func claim() -> Reward {
        guard canClaimToday else { return todaysReward }

        let newStreak = currentStreak + 1
        let reward = Self.reward(forStreakDay: newStreak)

        UserDefaults.standard.set(Date(), forKey: lastClaimKey)
        UserDefaults.standard.set(newStreak, forKey: streakKey)

        UsageLimitService.shared.addBonusAI(reward.aiCredits)
        UsageLimitService.shared.addBonusSwipes(reward.bonusSwipes)

        currentStreak = newStreak
        canClaimToday = false

        return reward
    }
}
