//
//  AnalyticsService.swift
//  WingmanAI
//

import Foundation
import Supabase

// MARK: - Events

enum AnalyticsEvent: String {
    case swipeLike          = "swipe_like"
    case swipeNope          = "swipe_nope"
    case matchCreated       = "match_created"
    case messageSent        = "message_sent"
    case wingmanUsed        = "wingman_used"
    case wingmanSuggestionTapped = "wingman_suggestion_tapped"
    case profileView        = "profile_view"
    case boostActivated     = "boost_activated"
    case subscriptionStarted = "subscription_started"
    case dailyRewardClaimed = "daily_reward_claimed"
    case photoUploaded      = "photo_uploaded"
    case onboardingCompleted = "onboarding_completed"
    case appOpened          = "app_opened"
}

// MARK: - Service

final class AnalyticsService {
    static let shared = AnalyticsService()
    private init() {}

    private let queueKey = "analytics_event_queue"
    private let maxQueueSize = 100
    private var isFlushing = false

    // MARK: - Track

    func track(_ event: AnalyticsEvent, properties: [String: String] = [:]) {
        var payload: [String: String] = [
            "event": event.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "user_id": currentUserId() ?? "anonymous"
        ]
        payload.merge(properties) { _, new in new }

        enqueue(payload)

        // Fire-and-forget flush in background
        Task.detached(priority: .utility) { [weak self] in
            await self?.flush()
        }
    }

    // MARK: - Queue (UserDefaults ring buffer)

    private func enqueue(_ event: [String: String]) {
        var queue = loadQueue()
        queue.append(event)
        if queue.count > maxQueueSize {
            queue = Array(queue.suffix(maxQueueSize))
        }
        saveQueue(queue)
    }

    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let queue = loadQueue()
        guard !queue.isEmpty else { return }

        do {
            // Each event is a row in the analytics_events table
            let rows = queue.map { props -> AnalyticsRow in
                AnalyticsRow(
                    event_name: props["event"] ?? "",
                    user_id: props["user_id"],
                    properties: props.filter { $0.key != "event" && $0.key != "user_id" },
                    created_at: props["timestamp"] ?? ISO8601DateFormatter().string(from: Date())
                )
            }

            try await SupabaseClientProvider.shared.client
                .from("analytics_events")
                .insert(rows)
                .execute()

            saveQueue([])
        } catch {
            // Silent fail — events stay in queue for next flush
        }
    }

    // MARK: - Helpers

    private func currentUserId() -> String? {
        SupabaseClientProvider.shared.client.auth.currentSession?.user.id.uuidString
    }

    private func loadQueue() -> [[String: String]] {
        guard let data = UserDefaults.standard.data(forKey: queueKey),
              let decoded = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveQueue(_ queue: [[String: String]]) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        UserDefaults.standard.set(data, forKey: queueKey)
    }

    // MARK: - Row model

    private struct AnalyticsRow: Encodable {
        let event_name: String
        let user_id: String?
        let properties: [String: String]
        let created_at: String
    }
}
