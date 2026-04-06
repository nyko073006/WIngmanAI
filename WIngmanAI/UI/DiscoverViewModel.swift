import Foundation
import Combine
import Supabase
import StoreKit
import UIKit

private let discoverISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// Moved out of load() so the type is resolved once, not on every call
private struct DiscoverRow: Decodable {
    let user_id: UUID
    let updated_at: Date?
    let display_name: String?
    let city: String?
    let bio: String?
    let interests: [String]?
    let birthdate: String?
    let primary_photo_url: String?
    let distance_km: Double?
    let last_active_at: Date?
}

@MainActor
final class DiscoverViewModel: ObservableObject {

    private let swipeService = SwipeService.shared
    private let pageSize: Int = 40
    private var preloadTask: Task<Void, Never>? = nil

    // Core paging state
    @Published private(set) var profiles: [PublicProfile] = []
    private var seenUserIds: Set<UUID> = []
    private var hasMore: Bool = true
    private var cursorUpdatedAt: Date? = nil
    private var cursorUserId: UUID? = nil

    // UI state
    @Published var isLoading: Bool = false
    @Published var isSwiping: Bool = false
    @Published var errorText: String? = nil
    @Published var showSwipeLimitSheet: Bool = false
    @Published var showRewindLimitSheet: Bool = false

    // Relaxed discover (user-triggered)
    @Published var isRelaxed: Bool = false

    // Search filter overrides (session-only; loaded from profile on first use)
    @Published var filterAgeMin: Int = 18
    @Published var filterAgeMax: Int = 45
    @Published var filterDistanceKm: Int = 50
    @Published var filterLookingFor: String = "_all_"
    @Published var filterInterestedIn: String = "_all_"

    private var filterDefaultsLoaded = false
    private var defaultAgeMin: Int = 18
    private var defaultAgeMax: Int = 45
    private var defaultDistanceKm: Int = 50
    private var defaultLookingFor: String = "_all_"
    private var defaultInterestedIn: String = "_all_"

    var hasActiveFilters: Bool {
        filterAgeMin != defaultAgeMin ||
        filterAgeMax != defaultAgeMax ||
        filterDistanceKm != defaultDistanceKm ||
        filterLookingFor != defaultLookingFor ||
        filterInterestedIn != defaultInterestedIn ||
        isRelaxed
    }

    // Match overlay state
    @Published var showMatchAlert: Bool = false
    @Published var matchedUser: PublicProfile? = nil
    @Published var matchedMatchId: UUID? = nil
    @Published var matchedUserPhotoUrl: String? = nil

    // Photo URL lookup for cards/overlay (must be String URLs)
    @Published var primaryPhotoByUserId: [UUID: String] = [:]
    // All photos per user (ordered by sort_order) for gallery
    @Published var allPhotosByUserId: [UUID: [String]] = [:]

    // Undo last swipe
    @Published private(set) var lastSwipedProfile: PublicProfile? = nil
    private var lastSwipedPhotoUrls: [String] = []
    private(set) var lastSwipeWasLike: Bool = false

    // Convenience for the view
    var currentProfile: PublicProfile? { profiles.first }

    // MARK: - Public API

    func refresh(myUserId: UUID) async {
        preloadTask?.cancel()
        preloadTask = nil
        profiles = []
        primaryPhotoByUserId = [:]
        allPhotosByUserId = [:]
        seenUserIds = []
        hasMore = true
        cursorUpdatedAt = nil
        cursorUserId = nil
        showMatchAlert = false
        matchedUser = nil
        matchedMatchId = nil
        matchedUserPhotoUrl = nil
        isRelaxed = false
        lastSwipedProfile = nil; lastSwipedPhotoUrls = []; lastSwipeWasLike = false
        await load(myUserId: myUserId)
    }

    func setRelaxed(_ value: Bool, myUserId: UUID) async {
        preloadTask?.cancel()
        preloadTask = nil
        isRelaxed = value
        profiles = []
        primaryPhotoByUserId = [:]
        allPhotosByUserId = [:]
        seenUserIds = []
        hasMore = true
        cursorUpdatedAt = nil
        cursorUserId = nil
        errorText = nil
        showMatchAlert = false
        matchedUser = nil
        matchedMatchId = nil
        matchedUserPhotoUrl = nil
        lastSwipedProfile = nil; lastSwipedPhotoUrls = []; lastSwipeWasLike = false
        await load(myUserId: myUserId)
    }

    func load(myUserId: UUID) async {
        guard hasMore, !isLoading else { return }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        var params: [String: String] = [
            "p_limit": String(pageSize),
            "p_relaxed": isRelaxed ? "true" : "false",
            "p_age_min": String(filterAgeMin),
            "p_age_max": String(filterAgeMax),
            "p_distance_km": String(filterDistanceKm),
            "p_looking_for_filter": filterLookingFor,
            "p_interested_in": filterInterestedIn
        ]
        if let cu = cursorUpdatedAt {
            params["p_cursor_updated_at"] = discoverISO8601.string(from: cu)
        }
        if let cid = cursorUserId {
            params["p_cursor_user_id"] = cid.uuidString
        }

        let rows: [DiscoverRow]
        do {
            rows = try await SupabaseClientProvider.shared.client
                .rpc("get_discover_profiles", params: params)
                .execute()
                .value
        } catch {
            self.errorText = AppError.userMessage(for: error)
            return
        }

        let existingIds = Set(self.profiles.map { $0.id })

        let candidates: [PublicProfile] = rows.map {
            PublicProfile(
                id: $0.user_id,
                displayName: $0.display_name ?? "",
                city: $0.city,
                bio: $0.bio ?? "",
                interests: $0.interests ?? [],
                birthdate: $0.birthdate,
                distanceKm: $0.distance_km.map { Int($0.rounded()) },
                lastActiveAt: $0.last_active_at
            )
        }

        let newOnes = candidates.filter { !seenUserIds.contains($0.id) && !existingIds.contains($0.id) }
        if !newOnes.isEmpty {
            self.profiles.append(contentsOf: newOnes)
            self.seenUserIds.formUnion(newOnes.map { $0.id })
        }

        for r in rows {
            if let url = r.primary_photo_url {
                self.primaryPhotoByUserId[r.user_id] = url
            }
        }

        if let last = rows.last {
            cursorUpdatedAt = last.updated_at
            cursorUserId = last.user_id
        }

        if rows.count < pageSize {
            hasMore = false
        }

        // Fetch all photos for new profiles (batch)
        let newUserIds = newOnes.map { $0.id }
        if !newUserIds.isEmpty {
            preloadTask?.cancel()
            preloadTask = Task {
                await self.fetchAllPhotos(for: newUserIds)
            }
        }
    }

    private func fetchAllPhotos(for userIds: [UUID]) async {
        struct PhotoRow: Decodable {
            let user_id: UUID
            let url: String
            let sort_order: Int?
            let is_primary: Bool?
        }
        do {
            let photos: [PhotoRow] = try await SupabaseClientProvider.shared.client
                .from("photos")
                .select("user_id,url,sort_order,is_primary")
                .in("user_id", values: userIds.map { $0.uuidString })
                .order("sort_order", ascending: true)
                .execute()
                .value

            var grouped: [UUID: [String]] = [:]
            for p in photos {
                grouped[p.user_id, default: []].append(p.url)
            }
            for (uid, urls) in grouped {
                self.allPhotosByUserId[uid] = urls
            }
            
            // Preload images into disk/memory cache for instant swipe rendering
            Task.detached(priority: .background) {
                for photo in photos {
                    guard let url = URL(string: photo.url) else { continue }
                    await ImageCache.shared.preload(url)
                }
            }
        } catch {
            print("Photos fetch failed (background): \(error)")
        }
    }

    func swipe(myUserId: UUID, isLike: Bool) async {
        guard !isSwiping else { return }
        guard let target = profiles.first else { return }

        guard UsageLimitService.shared.canSwipe() else {
            showSwipeLimitSheet = true
            return
        }

        isSwiping = true
        defer { isSwiping = false }

        errorText = nil

        // Capture photo URLs before clearing (needed for match overlay + undo)
        let targetPhotoUrl = allPhotosByUserId[target.id]?.first ?? primaryPhotoByUserId[target.id]
        let targetAllPhotos = allPhotosByUserId[target.id] ?? (targetPhotoUrl.map { [$0] } ?? [])

        // Save for potential undo (overwrite any previous)
        lastSwipedProfile = target
        lastSwipedPhotoUrls = targetAllPhotos
        lastSwipeWasLike = isLike

        // Optimistic UI: remove first
        profiles.removeFirst()
        primaryPhotoByUserId[target.id] = nil
        allPhotosByUserId[target.id] = nil

        UsageLimitService.shared.recordSwipe()

        do {
            try await swipeService.upsertSwipe(swiperId: myUserId, targetId: target.id, isLike: isLike)

            if isLike {
                if let matchId = await matchIdIfExists(myUserId: myUserId, otherUserId: target.id) {
                    matchedMatchId = matchId
                    matchedUser = target
                    matchedUserPhotoUrl = targetPhotoUrl
                    showMatchAlert = true
                    // Can't undo a match — clear undo state
                    lastSwipedProfile = nil; lastSwipedPhotoUrls = []; lastSwipeWasLike = false

                    // Ask for a review on first match only
                    let alreadyAsked = UserDefaults.standard.bool(forKey: "review_requested")
                    if !alreadyAsked {
                        UserDefaults.standard.set(true, forKey: "review_requested")
                        Task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            if let scene = UIApplication.shared.connectedScenes
                                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                                AppStore.requestReview(in: scene)
                            }
                        }
                    }
                }
            }

            if profiles.count < 5, hasMore {
                await load(myUserId: myUserId)
            }
        } catch {
            // Rollback
            profiles.insert(target, at: 0)
            allPhotosByUserId[target.id] = targetAllPhotos
            if let url = targetPhotoUrl { primaryPhotoByUserId[target.id] = url }
            lastSwipedProfile = nil; lastSwipedPhotoUrls = []; lastSwipeWasLike = false
            errorText = AppError.userMessage(for: error)
        }
    }

    func undoSwipe(myUserId: UUID) async {
        guard let profile = lastSwipedProfile else { return }

        guard UsageLimitService.shared.canRewind() else {
            showRewindLimitSheet = true
            return
        }

        UsageLimitService.shared.recordRewind()

        do {
            try await swipeService.deleteSwipe(swiperId: myUserId, targetId: profile.id)
        } catch {
            errorText = AppError.userMessage(for: error)
            lastSwipedProfile = nil; lastSwipedPhotoUrls = []; lastSwipeWasLike = false
            return
        }

        // Restore profile to front of stack
        profiles.insert(profile, at: 0)
        seenUserIds.remove(profile.id)
        allPhotosByUserId[profile.id] = lastSwipedPhotoUrls
        if let primary = lastSwipedPhotoUrls.first {
            primaryPhotoByUserId[profile.id] = primary
        }

        lastSwipedProfile = nil; lastSwipedPhotoUrls = []; lastSwipeWasLike = false
    }

    func blockUser(myUserId: UUID, targetId: UUID) async {
        profiles.removeAll { $0.id == targetId }
        primaryPhotoByUserId[targetId] = nil
        allPhotosByUserId[targetId] = nil
        seenUserIds.insert(targetId)
        do {
            try await swipeService.block(blockerId: myUserId, blockedId: targetId)
        } catch {
            // silent — card already removed
        }
        if profiles.count < 5, hasMore {
            await load(myUserId: myUserId)
        }
    }

    // MARK: - Private helpers

    // MARK: - Search filter management

    func loadFilterDefaults(myUserId: UUID) async {
        guard !filterDefaultsLoaded else { return }
        filterDefaultsLoaded = true
        struct Row: Decodable {
            let age_min: Int?
            let age_max: Int?
            let distance_km: Int?
            let looking_for: String?
            let interested_in_arr: [String]?
        }
        do {
            let rows: [Row] = try await SupabaseClientProvider.shared.client
                .from("profiles")
                .select("age_min,age_max,distance_km,looking_for,interested_in_arr")
                .eq("user_id", value: myUserId.uuidString)
                .limit(1)
                .execute()
                .value
            if let r = rows.first {
                let ageMin = max(18, min(r.age_min ?? 18, 78))
                let ageMax = max(ageMin + 1, min(r.age_max ?? 45, 80)) // always > ageMin
                let distKm = r.distance_km ?? 50
                let lookingFor = r.looking_for ?? "_all_"
                let arr = (r.interested_in_arr ?? []).filter { $0 != "Alle" && $0 != "all" }
                let interestedIn = arr.isEmpty ? "_all_" : arr.joined(separator: ",")

                filterAgeMin = ageMin;    filterAgeMax = ageMax
                filterDistanceKm = distKm; filterLookingFor = lookingFor
                filterInterestedIn = interestedIn

                defaultAgeMin = ageMin;    defaultAgeMax = ageMax
                defaultDistanceKm = distKm; defaultLookingFor = lookingFor
                defaultInterestedIn = interestedIn
            }
        } catch { /* silent – defaults remain */ }
    }

    func applyFilters(myUserId: UUID) async {
        preloadTask?.cancel(); preloadTask = nil
        profiles = []; primaryPhotoByUserId = [:]; allPhotosByUserId = [:]
        seenUserIds = []; hasMore = true
        cursorUpdatedAt = nil; cursorUserId = nil
        errorText = nil; showMatchAlert = false
        matchedUser = nil; matchedMatchId = nil; matchedUserPhotoUrl = nil
        lastSwipedProfile = nil; lastSwipedPhotoUrls = []; lastSwipeWasLike = false
        await load(myUserId: myUserId)
    }

    func resetFilters(myUserId: UUID) async {
        filterAgeMin = defaultAgeMin;    filterAgeMax = defaultAgeMax
        filterDistanceKm = defaultDistanceKm; filterLookingFor = defaultLookingFor
        filterInterestedIn = defaultInterestedIn; isRelaxed = false
        await applyFilters(myUserId: myUserId)
    }

    private func matchIdIfExists(myUserId: UUID, otherUserId: UUID) async -> UUID? {
        let low = min(myUserId, otherUserId)
        let high = max(myUserId, otherUserId)

        struct Row: Decodable { let id: UUID }

        do {
            let rows: [Row] = try await SupabaseClientProvider.shared.client
                .from("matches")
                .select("id")
                .eq("user_low", value: low.uuidString)
                .eq("user_high", value: high.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first?.id
        } catch {
            return nil
        }
    }
}
