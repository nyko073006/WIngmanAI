import Foundation
import Combine
import Supabase

fileprivate struct DiscoverProfilesParams: Encodable {
    let p_limit: Int
    let p_cursor_updated_at: Date?
    let p_cursor_user_id: String?

    init(limit: Int, cursorUpdatedAt: Date?, cursorUserId: UUID?) {
        self.p_limit = limit
        self.p_cursor_updated_at = cursorUpdatedAt
        self.p_cursor_user_id = cursorUserId?.uuidString
    }
}

@MainActor
final class DiscoverViewModel: ObservableObject {

    private let swipeService = SwipeService.shared
    private let pageSize: Int = 40

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

    // Match overlay state
    @Published var showMatchAlert: Bool = false
    @Published var matchedUser: PublicProfile? = nil
    @Published var matchedMatchId: UUID? = nil

    // Photo URL lookup for cards/overlay (must be String URLs)
    @Published var primaryPhotoByUserId: [UUID: String] = [:]

    // Convenience for the view
    var currentProfile: PublicProfile? {
        profiles.first
    }

    // MARK: - Public API

    func refresh(myUserId: UUID) async {
        profiles = []
        primaryPhotoByUserId = [:]
        seenUserIds = []
        hasMore = true
        cursorUpdatedAt = nil
        cursorUserId = nil
        showMatchAlert = false
        matchedUser = nil
        matchedMatchId = nil
        await load(myUserId: myUserId)
    }

    func load(myUserId: UUID) async {
        guard hasMore, !isLoading else { return }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        struct DiscoverRow: Decodable {
            let user_id: UUID
            let updated_at: Date?
            let display_name: String?
            let city: String?
            let bio: String?
            let interests: [String]?
            let birthdate: String?
            let primary_photo_url: String?
        }

        let params = DiscoverProfilesParams(
            limit: pageSize,
            cursorUpdatedAt: cursorUpdatedAt,
            cursorUserId: cursorUserId
        )

        let rows: [DiscoverRow]
        do {
            rows = try await SupabaseClientProvider.shared.client
                .rpc("get_discover_profiles", params: params)
                .execute()
                .value
        } catch {
            self.errorText = error.localizedDescription
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
                birthdate: $0.birthdate
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

        // Update cursor from the last row (for next page)
        if let last = rows.last {
            cursorUpdatedAt = last.updated_at
            cursorUserId = last.user_id
        }

        // If server returns less than limit, we reached the end
        if rows.count < pageSize {
            hasMore = false
        }
    }

    func swipe(myUserId: UUID, isLike: Bool) async {
        guard !isSwiping else { return }
        guard let target = profiles.first else { return }

        isSwiping = true
        defer { isSwiping = false }

        errorText = nil

        // Optimistic UI: remove first
        profiles.removeFirst()
        primaryPhotoByUserId[target.id] = nil

        do {
            try await swipeService.upsertSwipe(swiperId: myUserId, targetId: target.id, isLike: isLike)

            if isLike {
                if let matchId = await matchIdIfExists(myUserId: myUserId, otherUserId: target.id) {
                    matchedMatchId = matchId
                    matchedUser = target
                    showMatchAlert = true
                }
            }

            if profiles.count < 5, hasMore {
                await load(myUserId: myUserId)
            }
        } catch {
            // Rollback
            profiles.insert(target, at: 0)
            errorText = error.localizedDescription
        }
    }

    // MARK: - Private helpers

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
