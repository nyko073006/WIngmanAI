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

    private func callFunction(_ name: String, body: Data) async throws -> Data {
        let url = SupabaseClientProvider.shared.supabaseURL
            .appendingPathComponent("functions/v1/\(name)")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseClientProvider.shared.anonKey, forHTTPHeaderField: "apikey")
        if let token = SupabaseClientProvider.shared.client.auth.currentSession?.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "AIService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw)"])
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
        case playful, witty, direct, warm, serious
    }

    enum BioLength: String, Codable, CaseIterable {
        case short   // 1–2 lines
        case medium  // 3–5 lines
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

// MARK: - JSON helpers

private extension JSONEncoder {
    static let ai: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return enc
    }()
}
