//
//  UsageLimitService.swift
//  WIngmanAI
//

import Foundation
import Combine
import Supabase

@MainActor
final class UsageLimitService: ObservableObject {
    static let shared = UsageLimitService()

    // MARK: - Tier Limits

    struct Limits {
        let swipesPerDay: Int
        let aiCreditsPerDay: Int
        let rewindsPerDay: Int
        let boostsPerWeek: Int
        let inkognito: Bool
        let likesWindowHours: Int? // nil = alle Likes sichtbar
    }

    static let free    = Limits(swipesPerDay: 25,  aiCreditsPerDay: 10, rewindsPerDay: 3,   boostsPerWeek: 0, inkognito: false, likesWindowHours: 6)
    static let premium = Limits(swipesPerDay: 50,  aiCreditsPerDay: 25, rewindsPerDay: 10,  boostsPerWeek: 1, inkognito: true,  likesWindowHours: 12)
    static let elite   = Limits(swipesPerDay: 500, aiCreditsPerDay: 50, rewindsPerDay: 500, boostsPerWeek: 3, inkognito: true,  likesWindowHours: nil)

    // MARK: - Keys

    private var userPrefix: String {
        guard let id = SupabaseClientProvider.shared.client.auth.currentSession?.user.id.uuidString else { return "guest_" }
        return id + "_"
    }

    private var swipeDateKey: String   { userPrefix + "usage_swipe_date" }
    private var swipeCountKey: String  { userPrefix + "usage_swipe_count" }
    private var aiDateKey: String      { userPrefix + "usage_ai_date" }
    private var aiCountKey: String     { userPrefix + "usage_ai_count" }
    private var rewindDateKey: String  { userPrefix + "usage_rewind_date" }
    private var rewindCountKey: String { userPrefix + "usage_rewind_count" }
    // Bonus credits are now date-scoped to avoid unlimited accumulation
    private var bonusAIKey: String       { userPrefix + "bonus_ai_credits" }
    private var bonusAIDateKey: String   { userPrefix + "bonus_ai_date" }
    private var bonusSwipesKey: String   { userPrefix + "bonus_swipes" }
    private var bonusSwipesDateKey: String { userPrefix + "bonus_swipes_date" }

    private init() {}

    // MARK: - Active Limits

    var current: Limits {
        switch PremiumService.shared.currentTier {
        case .elite:   return Self.elite
        case .premium: return Self.premium
        case .none:    return Self.free
        }
    }

    // MARK: - Swipes

    var remainingSwipes: Int {
        let used = todayCount(dateKey: swipeDateKey, countKey: swipeCountKey)
        let bonus = todayBonus(countKey: bonusSwipesKey, dateKey: bonusSwipesDateKey)
        return max(0, current.swipesPerDay + bonus - used)
    }

    func canSwipe() -> Bool { remainingSwipes > 0 }

    func recordSwipe() { increment(dateKey: swipeDateKey, countKey: swipeCountKey) }

    // MARK: - AI Credits

    var remainingAI: Int {
        let used = todayCount(dateKey: aiDateKey, countKey: aiCountKey)
        let bonus = todayBonus(countKey: bonusAIKey, dateKey: bonusAIDateKey)
        return max(0, current.aiCreditsPerDay + bonus - used)
    }

    func canUseAI() -> Bool { remainingAI > 0 }

    func recordAIUse() { increment(dateKey: aiDateKey, countKey: aiCountKey) }

    // MARK: - Rewinds

    var remainingRewinds: Int {
        max(0, current.rewindsPerDay - todayCount(dateKey: rewindDateKey, countKey: rewindCountKey))
    }

    func canRewind() -> Bool { remainingRewinds > 0 }

    func recordRewind() { increment(dateKey: rewindDateKey, countKey: rewindCountKey) }

    // MARK: - Bonus (from Daily Rewards)

    /// Adds bonus AI credits that expire at end of day (prevents unlimited accumulation)
    func addBonusAI(_ amount: Int) {
        let existing = todayBonus(countKey: bonusAIKey, dateKey: bonusAIDateKey)
        UserDefaults.standard.set(Date(), forKey: bonusAIDateKey)
        UserDefaults.standard.set(existing + amount, forKey: bonusAIKey)
    }

    /// Adds bonus swipes that expire at end of day
    func addBonusSwipes(_ amount: Int) {
        let existing = todayBonus(countKey: bonusSwipesKey, dateKey: bonusSwipesDateKey)
        UserDefaults.standard.set(Date(), forKey: bonusSwipesDateKey)
        UserDefaults.standard.set(existing + amount, forKey: bonusSwipesKey)
    }

    // MARK: - Likes Window

    /// Frühestes Datum ab dem Likes sichtbar sind. nil = kein Limit (Elite)
    var likesWindowDate: Date? {
        guard let hours = current.likesWindowHours else { return nil }
        return Date().addingTimeInterval(-Double(hours) * 3600)
    }

    // MARK: - Helpers

    private func todayCount(dateKey: String, countKey: String) -> Int {
        let defaults = UserDefaults.standard
        guard let last = defaults.object(forKey: dateKey) as? Date,
              Calendar.current.isDateInToday(last) else { return 0 }
        return defaults.integer(forKey: countKey)
    }

    /// Returns bonus credits only if they were awarded today; otherwise 0.
    private func todayBonus(countKey: String, dateKey: String) -> Int {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: dateKey) as? Date,
              Calendar.current.isDateInToday(date) else { return 0 }
        return defaults.integer(forKey: countKey)
    }

    private func increment(dateKey: String, countKey: String) {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: dateKey) as? Date ?? .distantPast
        let count = Calendar.current.isDateInToday(last) ? defaults.integer(forKey: countKey) : 0
        defaults.set(Date(), forKey: dateKey)
        defaults.set(count + 1, forKey: countKey)
    }
}
