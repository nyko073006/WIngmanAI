//
//  AIService.swift
//  WingmanAI
//
//  Created by Nyko on 13.02.26.
//

import Foundation
import Supabase

final class AIService {
    static let shared = AIService()
    private init() {}

    // No longer using static accessToken, we fetch dynamically to prevent stale token 401s
    // static var accessToken: String?

    private func callFunction(_ name: String, body: Data) async throws -> Data {
        return try await callFunctionWithToken(name, body: body, isRetry: false)
    }

    private func callFunctionWithToken(_ name: String, body: Data, isRetry: Bool) async throws -> Data {
        // Get a valid token — session property auto-refreshes if expired
        let token: String
        if isRetry {
            token = try await SupabaseClientProvider.shared.client.auth.refreshSession().accessToken
        } else {
            token = try await SupabaseClientProvider.shared.client.auth.session.accessToken
        }

        let url = SupabaseClientProvider.shared.supabaseURL
            .appendingPathComponent("functions/v1/\(name)")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseClientProvider.shared.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        // 401 → try once more with a force-refreshed token
        if http.statusCode == 401, !isRetry {
            return try await callFunctionWithToken(name, body: body, isRetry: true)
        }

        guard (200...299).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String? }
            let bodyMsg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw NSError(domain: "AIService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: bodyMsg ?? "HTTP \(http.statusCode)"])
        }
        return data
    }

    func generateBio(input: BioInput) async throws -> BioResponse {
        let body = try JSONEncoder.ai.encode(BioPayload(from: input))
        let data = try await callFunction("ai-bio", body: body)
        return try JSONDecoder().decode(BioResponse.self, from: data)
    }

    func generatePromptAnswers(input: PromptsInput) async throws -> PromptsResponse {
        let body = try JSONEncoder.ai.encode(PromptsPayload(from: input))
        let data = try await callFunction("ai-prompts", body: body)
        return try JSONDecoder().decode(PromptsResponse.self, from: data)
    }

    func generateHooks(input: HooksInput) async throws -> HooksResponse {
        let body = try JSONEncoder.ai.encode(HooksPayload(from: input))
        let data = try await callFunction("ai-hooks", body: body)
        return try JSONDecoder().decode(HooksResponse.self, from: data)
    }

    func generateChatSuggestions(input: WingmanInput) async throws -> WingmanResponse {
        let body = try JSONEncoder.ai.encode(input)
        let data = try await callFunction("ai-wingman", body: body)
        return try JSONDecoder().decode(WingmanResponse.self, from: data)
    }

    // MARK: - New Router API

    /// Send any task through the unified ai-router pipeline.
    /// Returns structured WingmanRouterResponse with variants, confidence, memory candidates etc.
    func route(_ request: WingmanRouterRequest) async throws -> WingmanRouterResponse {
        let body = try JSONEncoder.ai.encode(request)
        let data = try await callFunction("ai-router", body: body)
        return try JSONDecoder().decode(WingmanRouterResponse.self, from: data)
    }

    /// Convenience: message suggestion for a chat
    func suggestMessage(
        conversationId: String,
        chatHistory: [WingmanMessage],
        matchProfile: WingmanMatchProfile? = nil,
        screenContext: String? = nil
    ) async throws -> WingmanRouterResponse {
        let req = WingmanRouterRequest(
            taskType: "message_suggestion",
            conversationId: conversationId,
            screenContext: screenContext,
            chatHistory: chatHistory,
            matchProfile: matchProfile
        )
        return try await route(req)
    }

    /// Convenience: analyse a reply / conversation
    func analyseConversation(
        conversationId: String,
        chatHistory: [WingmanMessage],
        matchProfile: WingmanMatchProfile? = nil
    ) async throws -> WingmanRouterResponse {
        let req = WingmanRouterRequest(
            taskType: "reply_analysis",
            conversationId: conversationId,
            chatHistory: chatHistory,
            matchProfile: matchProfile
        )
        return try await route(req)
    }
}


// MARK: - Payloads sent to Edge Functions

private struct BioPayload: Encodable {
    let displayName: String?
    let gender: String?
    let interestedIn: [String]?
    let city: String?
    let lookingFor: String?
    let interests: [String]
    let keywords: [String]
    let tone: String
    let length: String
    let adjustment: String?

    init(from input: BioInput) {
        displayName = input.displayName
        gender = input.gender
        interestedIn = input.interestedIn
        city = input.city
        lookingFor = input.lookingFor
        interests = input.interests
        keywords = input.keywords
        tone = input.tone.rawValue
        length = input.length.rawValue
        adjustment = input.adjustment?.rawValue
    }
}

private struct PromptsPayload: Encodable {
    let displayName: String?
    let gender: String?
    let interestedIn: [String]?
    let city: String?
    let lookingFor: String?
    let interests: [String]
    let prompts: [String]
    let style: String
    let adjustment: String?

    init(from input: PromptsInput) {
        displayName = input.displayName
        gender = input.gender
        interestedIn = input.interestedIn
        city = input.city
        lookingFor = input.lookingFor
        interests = input.interests
        prompts = input.prompts
        style = input.style.rawValue
        adjustment = input.adjustment?.rawValue
    }
}

private struct HooksPayload: Encodable {
    let gender: String?
    let interestedIn: [String]?
    let city: String?
    let lookingFor: String?
    let bio: String?
    let interests: [String]
    let promptAnswers: [String]?
    let maxHooks: Int
    let maxVibes: Int

    init(from input: HooksInput) {
        gender = input.gender
        interestedIn = input.interestedIn
        city = input.city
        lookingFor = input.lookingFor
        bio = input.bio
        interests = input.interests
        promptAnswers = input.promptAnswers
        maxHooks = input.maxHooks
        maxVibes = input.maxVibes
    }
}

// MARK: - Models

struct BioResponse: Codable {
    let bios: [String]
}

struct PromptsResponse: Codable {
    /// 3 groups (one per prompt), each containing multiple suggested answers.
    let answers: [[String]]
}

struct HooksResponse: Codable {
    let hooks: [String]
    let firstDateVibes: [String]
}

struct WingmanMessage: Codable {
    let role: String   // "me" | "them"
    let text: String
}

struct WingmanInput: Codable {
    let theirName: String
    let theirBio: String?
    let theirInterests: [String]
    let conversation: [WingmanMessage]
}

struct WingmanResponse: Codable {
    let suggestions: [String]
}

/// Keep these payloads SMALL. The whole point is 120s onboarding, not essays.

struct BioInput: Codable {
    // Core profile context
    var displayName: String?
    var gender: String?
    var interestedIn: [String]?
    var city: String?
    var lookingFor: String? // serious/casual/friends/not_sure

    // Selection UI
    var interests: [String] // 5–10
    var keywords: [String]  // exactly 3 in your UI (optional but recommended)

    // Controls
    var tone: Tone
    var length: BioLength

    // Quick adjustments
    var adjustment: Adjustment?

    enum Tone: String, Codable, CaseIterable {
        case playful, witty, direct, warm, serious, authentic
    }

    enum BioLength: String, Codable, CaseIterable {
        case short   // 1–2 sentences
        case medium  // 3–4 sentences
        case long    // 5–7 sentences
    }

    enum Adjustment: String, Codable {
        case moreFunny = "more_funny"
        case moreFlirtySafe = "more_flirty_safe"
        case moreSerious = "more_serious"
        case shorter
        case moreConfident = "more_confident"
        case morePolite = "more_polite"
    }
}

struct PromptsInput: Codable {
    // Context
    var displayName: String?
    var gender: String?
    var interestedIn: [String]?
    var city: String?
    var lookingFor: String?
    var interests: [String]

    // The 3 prompt titles (e.g. "A perfect Sunday is...")
    var prompts: [String] // exactly 3

    // Control
    var style: PromptStyle
    var adjustment: PromptAdjustment?

    enum PromptStyle: String, Codable {
        case balanced
        case funnier
        case flirtySafe = "flirty_safe"
        case shorter
        case moreConfident = "more_confident"
    }

    enum PromptAdjustment: String, Codable {
        case regenerate
        case funnier
        case flirtySafe = "flirty_safe"
        case shorter
        case moreConfident = "more_confident"
    }
}

struct HooksInput: Codable {
    var gender: String?
    var interestedIn: [String]?
    var city: String?
    var lookingFor: String?

    var bio: String?
    var interests: [String]

    // Optional: selected prompt answers to ground hooks
    var promptAnswers: [String]?

    // Control
    var maxHooks: Int
    var maxVibes: Int
}

// MARK: - Router Models

struct WingmanRouterRequest: Codable {
    let taskType: String
    var conversationId: String?
    var screenContext: String?
    var userInput: String?
    var userGoal: String?
    var chatHistory: [WingmanMessage]?
    var matchProfile: WingmanMatchProfile?
    var tone: String?
    var length: String?
    var interests: [String]?

    enum CodingKeys: String, CodingKey {
        case taskType       = "task_type"
        case conversationId = "conversation_id"
        case screenContext  = "screen_context"
        case userInput      = "user_input"
        case userGoal       = "user_goal"
        case chatHistory    = "chat_history"
        case matchProfile   = "match_profile"
        case tone, length, interests
    }
}

struct WingmanMatchProfile: Codable {
    var name: String?
    var age: Int?
    var bio: String?
    var interests: [String]?
    var city: String?
}

struct WingmanRouterResponse: Codable {
    // Message suggestions
    var variants: [WingmanVariant]?
    var bestVariantIndex: Int?
    var confidence: Double?
    var riskFlags: [String]?
    var memoryCandidates: [String]?
    var summary: String?
    var taskType: String?
    var uiHints: WingmanUIHints?
    var eventId: String?

    // Reply analysis
    var interestScore: Double?
    var interestLabel: String?
    var redFlags: [String]?
    var mistakesByUser: [String]?
    var recommendedNextMove: String?

    // Bio generation (router also handles bio)
    var bios: [String]?
    var bestIndex: Int?

    // Coaching
    var feedback: String?
    var actionItems: [String]?

    enum CodingKeys: String, CodingKey {
        case variants, confidence, summary, bios, feedback
        case bestVariantIndex   = "best_variant_index"
        case riskFlags          = "risk_flags"
        case memoryCandidates   = "memory_candidates"
        case taskType           = "task_type"
        case uiHints            = "ui_hints"
        case eventId            = "event_id"
        case interestScore      = "interest_score"
        case interestLabel      = "interest_label"
        case redFlags           = "red_flags"
        case mistakesByUser     = "mistakes_by_user"
        case recommendedNextMove = "recommended_next_move"
        case bestIndex          = "best_index"
        case actionItems        = "action_items"
    }
}

struct WingmanVariant: Codable, Identifiable {
    var id: String { label }
    let label: String  // safe | playful | bold
    let text: String
}

struct WingmanUIHints: Codable {
    var tone: String?
    var length: String?
}

// MARK: - JSON helpers

private extension JSONEncoder {
    static let ai: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return enc
    }()
}
