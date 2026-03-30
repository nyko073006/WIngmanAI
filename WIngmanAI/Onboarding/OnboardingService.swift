import Foundation
import Supabase
import PostgREST
import Auth

@MainActor
final class OnboardingService {
    static let shared = OnboardingService()
    private init() {}

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    // MARK: - Models

    private struct ProfileRow: Decodable {
        let onboarding_complete: Bool?
    }

    private struct ProfileUpsert: Encodable {
        let user_id: String
        let onboarding_complete: Bool
        let is_active: Bool
        let onboarding_completed_at: String?

        init(userId: UUID, onboardingComplete: Bool, isActive: Bool = true) {
            self.user_id = userId.uuidString
            self.onboarding_complete = onboardingComplete
            self.is_active = isActive
            self.onboarding_completed_at = onboardingComplete
                ? ISO8601DateFormatter.cached.string(from: Date())
                : nil
        }
    }

    /// Upsert für Onboarding-Daten (Profilfelder), OHNE onboarding_complete zu setzen.
    private struct ProfileDraftUpsert: Encodable {
        let user_id: String

        let display_name: String?
        let birthdate: String?
        let gender: String?
        let interested_in_arr: [String]?
        let bio: String?
        let city: String?
        let interests: [String]?

        let distance_km: Int?
        let age_min: Int?
        let age_max: Int?
        let looking_for: String?

        // jsonb columns
        let hooks: [String]?
        let first_date_vibes: [String]?

        let prompt_1: String?
        let answer_1: String?
        let prompt_2: String?
        let answer_2: String?
        let prompt_3: String?
        let answer_3: String?

        let updated_at: String?

        init(
            userId: UUID,
            displayName: String?,
            birthdate: Date?,
            gender: String?,
            interestedInArr: [String]?,
            bio: String?,
            city: String?,
            interests: [String]?,
            distanceKm: Int?,
            ageMin: Int?,
            ageMax: Int?,
            lookingFor: String?,
            hooks: [String]?,
            firstDateVibes: [String]?,
            prompt1: String?,
            answer1: String?,
            prompt2: String?,
            answer2: String?,
            prompt3: String?,
            answer3: String?
        ) {
            self.user_id = userId.uuidString

            self.display_name = Self.nilIfEmpty(displayName)
            self.birthdate = birthdate.map { Self.dateOnly($0) }
            self.gender = Self.nilIfEmpty(gender)
            self.interested_in_arr = Self.cleanInterestedInArr(interestedInArr)
            self.bio = Self.nilIfEmpty(bio)
            self.city = Self.nilIfEmpty(city)

            let cleanedInterests = (interests ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.interests = cleanedInterests.isEmpty ? nil : cleanedInterests

            self.distance_km = distanceKm
            self.age_min = ageMin
            self.age_max = ageMax
            self.looking_for = Self.nilIfEmpty(lookingFor)

            let cleanedHooks = (hooks ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.hooks = cleanedHooks.isEmpty ? nil : cleanedHooks

            let cleanedVibes = (firstDateVibes ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.first_date_vibes = cleanedVibes.isEmpty ? nil : cleanedVibes

            self.prompt_1 = Self.nilIfEmpty(prompt1)
            self.answer_1 = Self.nilIfEmpty(answer1)
            self.prompt_2 = Self.nilIfEmpty(prompt2)
            self.answer_2 = Self.nilIfEmpty(answer2)
            self.prompt_3 = Self.nilIfEmpty(prompt3)
            self.answer_3 = Self.nilIfEmpty(answer3)

            self.updated_at = ISO8601DateFormatter.cached.string(from: Date())
        }

        private static func nilIfEmpty(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        private static func cleanInterestedInArr(_ arr: [String]?) -> [String]? {
            let cleaned = (arr ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            if cleaned.isEmpty { return nil }

            // allow only the supported values
            let allowed: Set<String> = ["women", "men", "divers"]

            // If call sites still pass "all", expand it.
            if cleaned.contains("all") {
                return ["women", "men", "divers"]
            }

            // de-dup while preserving order
            var out: [String] = []
            var seen: Set<String> = []
            for v in cleaned {
                guard allowed.contains(v) else { continue }
                if !seen.contains(v) {
                    seen.insert(v)
                    out.append(v)
                }
            }

            return out.isEmpty ? nil : out
        }

        private static func dateOnly(_ date: Date) -> String {
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let y = comps.year ?? 2000
            let m = comps.month ?? 1
            let d = comps.day ?? 1
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
    }

    // MARK: - Draft model

    struct OnboardingDraft {
        let displayName: String?
        let birthdate: String?
        let gender: String?
        let interestedInArr: [String]?
        let bio: String?
        let city: String?
        let interests: [String]?
        let distanceKm: Int?
        let ageMin: Int?
        let ageMax: Int?
        let lookingFor: String?
    }

    // MARK: - Read

    /// Loads a previously saved draft from the profiles table.
    /// Returns nil if there's no meaningful data yet.
    func fetchProfileDraft(userId: UUID) async throws -> OnboardingDraft? {
        struct Row: Decodable {
            let display_name: String?
            let birthdate: String?
            let gender: String?
            let interested_in_arr: [String]?
            let bio: String?
            let city: String?
            let interests: [String]?
            let distance_km: Int?
            let age_min: Int?
            let age_max: Int?
            let looking_for: String?
        }

        let rows: [Row] = try await client
            .from("profiles")
            .select("display_name,birthdate,gender,interested_in_arr,bio,city,interests,distance_km,age_min,age_max,looking_for")
            .eq("user_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first,
              row.display_name != nil || row.bio != nil || row.city != nil || row.interests != nil
        else { return nil }

        return OnboardingDraft(
            displayName: row.display_name,
            birthdate: row.birthdate,
            gender: row.gender,
            interestedInArr: row.interested_in_arr,
            bio: row.bio,
            city: row.city,
            interests: row.interests,
            distanceKm: row.distance_km,
            ageMin: row.age_min,
            ageMax: row.age_max,
            lookingFor: row.looking_for
        )
    }

    /// Returns whether onboarding is complete.
    /// If the profile row does not exist yet => false.
    /// Real errors (RLS/network/schema) are thrown (damit du sie siehst).
    func fetchOnboardingComplete(userId: UUID) async throws -> Bool {
        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select("onboarding_complete")
            .eq("user_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        return rows.first?.onboarding_complete == true
    }

    // MARK: - Write

    /// Marks onboarding as complete. Uses upsert so it also works if the profile row doesn't exist yet.
    func setOnboardingComplete(userId: UUID, complete: Bool = true) async throws {
        _ = try await client
            .from("profiles")
            .upsert(
                ProfileUpsert(userId: userId, onboardingComplete: complete),
                onConflict: "user_id"
            )
            .execute()
    }

    /// Speichert die Onboarding-Daten ins Profil (Upsert). Setzt NICHT onboarding_complete.
    func upsertProfileDraft(
        userId: UUID,
        displayName: String?,
        birthdate: Date?,
        gender: String?,
        interestedInArr: [String]?,
        bio: String?,
        city: String?,
        interests: [String]?,
        distanceKm: Int? = nil,
        ageMin: Int? = nil,
        ageMax: Int? = nil,
        lookingFor: String? = nil,
        hooks: [String]? = nil,
        firstDateVibes: [String]? = nil,
        prompt1: String? = nil,
        answer1: String? = nil,
        prompt2: String? = nil,
        answer2: String? = nil,
        prompt3: String? = nil,
        answer3: String? = nil
    ) async throws {
        _ = try await client
            .from("profiles")
            .upsert(
                ProfileDraftUpsert(
                    userId: userId,
                    displayName: displayName,
                    birthdate: birthdate,
                    gender: gender,
                    interestedInArr: interestedInArr,
                    bio: bio,
                    city: city,
                    interests: interests,
                    distanceKm: distanceKm,
                    ageMin: ageMin,
                    ageMax: ageMax,
                    lookingFor: lookingFor,
                    hooks: hooks,
                    firstDateVibes: firstDateVibes,
                    prompt1: prompt1,
                    answer1: answer1,
                    prompt2: prompt2,
                    answer2: answer2,
                    prompt3: prompt3,
                    answer3: answer3
                ),
                onConflict: "user_id"
            )
            .execute()
    }

    // Backward-compatible wrapper (older call sites that still pass a single TEXT value)
    func upsertProfileDraft(
        userId: UUID,
        displayName: String?,
        birthdate: Date?,
        gender: String?,
        interestedIn: String?,
        bio: String?,
        city: String?,
        interests: [String]?,
        distanceKm: Int? = nil,
        ageMin: Int? = nil,
        ageMax: Int? = nil,
        lookingFor: String? = nil,
        hooks: [String]? = nil,
        firstDateVibes: [String]? = nil,
        prompt1: String? = nil,
        answer1: String? = nil,
        prompt2: String? = nil,
        answer2: String? = nil,
        prompt3: String? = nil,
        answer3: String? = nil
    ) async throws {
        let mapped: [String]?
        switch (interestedIn ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "women": mapped = ["women"]
        case "men": mapped = ["men"]
        case "divers": mapped = ["divers"]
        case "all": mapped = ["women", "men", "divers"]
        case "": mapped = nil
        default: mapped = nil
        }

        try await upsertProfileDraft(
            userId: userId,
            displayName: displayName,
            birthdate: birthdate,
            gender: gender,
            interestedInArr: mapped,
            bio: bio,
            city: city,
            interests: interests,
            distanceKm: distanceKm,
            ageMin: ageMin,
            ageMax: ageMax,
            lookingFor: lookingFor,
            hooks: hooks,
            firstDateVibes: firstDateVibes,
            prompt1: prompt1,
            answer1: answer1,
            prompt2: prompt2,
            answer2: answer2,
            prompt3: prompt3,
            answer3: answer3
        )
    }
}

private extension ISO8601DateFormatter {
    static let cached: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
