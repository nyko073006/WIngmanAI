//
//  BoostService.swift
//  WingmanAI
//
//  A "Boost" makes your profile appear first in other users' Discover stacks
//  for a fixed duration (30 minutes). The availability is governed by
//  UsageLimitService.boostsPerWeek per tier.
//

import Foundation
import Combine
import Supabase

@MainActor
final class BoostService: ObservableObject {
    static let shared = BoostService()

    @Published private(set) var isBoostActive: Bool = false
    @Published private(set) var boostExpiresAt: Date? = nil
    @Published var errorText: String? = nil

    static let durationSeconds: TimeInterval = 30 * 60  // 30 minutes

    private var expiryTimer: Task<Void, Never>? = nil
    private let boostActiveUntilKey = "boost_active_until"

    private init() {
        restoreFromDefaults()
    }

    // MARK: - Public

    var remainingSeconds: TimeInterval {
        guard let exp = boostExpiresAt else { return 0 }
        return max(0, exp.timeIntervalSinceNow)
    }

    var remainingFormatted: String {
        let s = Int(remainingSeconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var canActivate: Bool {
        !isBoostActive && weeklySlotsRemaining > 0
    }

    var weeklySlotsRemaining: Int {
        let limit = UsageLimitService.shared.current.boostsPerWeek
        let used = weeklyUsed()
        return max(0, limit - used)
    }

    func activate(userId: UUID) async {
        guard canActivate else { return }

        let until = Date().addingTimeInterval(Self.durationSeconds)
        do {
            try await SupabaseClientProvider.shared.client
                .from("profiles")
                .update(["boost_active_until": ISO8601DateFormatter().string(from: until)])
                .eq("user_id", value: userId.uuidString)
                .execute()

            boostExpiresAt = until
            isBoostActive = true
            recordWeeklyUse()
            persist(until: until)
            startExpiryTimer()
            AnalyticsService.shared.track(.boostActivated, properties: [
                "duration_sec": "\(Int(Self.durationSeconds))"
            ])
        } catch {
            errorText = "Boost konnte nicht aktiviert werden: \(error.localizedDescription)"
        }
    }

    // MARK: - Timer

    private func startExpiryTimer() {
        expiryTimer?.cancel()
        guard let exp = boostExpiresAt else { return }
        let delay = max(0, exp.timeIntervalSinceNow)
        expiryTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.isBoostActive = false
                self.boostExpiresAt = nil
                self.persist(until: nil)
            }
        }
    }

    // MARK: - Persistence

    private func restoreFromDefaults() {
        if let stored = UserDefaults.standard.object(forKey: boostActiveUntilKey) as? Date,
           stored > Date() {
            boostExpiresAt = stored
            isBoostActive = true
            startExpiryTimer()
        }
    }

    private func persist(until: Date?) {
        if let until {
            UserDefaults.standard.set(until, forKey: boostActiveUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: boostActiveUntilKey)
        }
    }

    // MARK: - Weekly use tracking

    private var weeklyUsedKey: String {
        let uid = SupabaseClientProvider.shared.client.auth.currentSession?.user.id.uuidString ?? "guest"
        return "\(uid)_boost_weekly"
    }
    private var weeklyDateKey: String { weeklyUsedKey + "_date" }

    private func weeklyUsed() -> Int {
        let defaults = UserDefaults.standard
        guard let stored = defaults.object(forKey: weeklyDateKey) as? Date else { return 0 }
        let cal = Calendar.current
        if !cal.isDate(stored, equalTo: Date(), toGranularity: .weekOfYear) { return 0 }
        return defaults.integer(forKey: weeklyUsedKey)
    }

    private func recordWeeklyUse() {
        let defaults = UserDefaults.standard
        let current = weeklyUsed()
        defaults.set(Date(), forKey: weeklyDateKey)
        defaults.set(current + 1, forKey: weeklyUsedKey)
    }
}
