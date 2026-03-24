//
//  LikesView.swift
//  WingmanAI
//

import SwiftUI
import Supabase

// MARK: - View

struct LikesView: View {
    let myId: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var likers: [LikerProfile] = []
    @State private var revealedId: UUID? = nil
    @State private var countdownText: String = ""
    @State private var countdownTimer: Timer? = nil
    @State private var errorText: String? = nil

    private let brand = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)
    private let brandAlt = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)

    // UserDefaults keys
    private let cooldownKey = "likes_last_reveal_date"
    private let revealedIdsKey = "likes_revealed_ids"
    private let cooldownDuration: TimeInterval = 6 * 3600

    // MARK: - Computed

    private var revealedIds: Set<UUID> {
        let stored = UserDefaults.standard.stringArray(forKey: revealedIdsKey) ?? []
        return Set(stored.compactMap { UUID(uuidString: $0) })
    }

    private var canReveal: Bool {
        guard let last = UserDefaults.standard.object(forKey: cooldownKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= cooldownDuration
    }

    private var nextRevealDate: Date? {
        guard let last = UserDefaults.standard.object(forKey: cooldownKey) as? Date else { return nil }
        let next = last.addingTimeInterval(cooldownDuration)
        return next > Date() ? next : nil
    }

    private var pendingLiker: LikerProfile? { likers.first }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorText {
                    VStack(spacing: 14) {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Erneut versuchen") { Task { await loadLikers() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if likers.isEmpty {
                    emptyState
                } else {
                    likerContent
                }
            }
            .navigationTitle("Wer mag dich?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") { dismiss() }
                        .tint(brand)
                }
            }
        }
        .task { await loadLikers() }
        .onDisappear { countdownTimer?.invalidate() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(brand.opacity(0.10))
                    .frame(width: 100, height: 100)
                Image(systemName: "heart.slash")
                    .font(.system(size: 38))
                    .foregroundStyle(brand.opacity(0.5))
            }
            VStack(spacing: 8) {
                Text("Noch keine Likes")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("Werde aktiv und like andere Profile –\ndann kommen die Likes zu dir.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Liker Content

    private var likerContent: some View {
        VStack(spacing: 24) {
            // Count pill
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(brand)
                Text(likers.count == 1 ? "1 Person mag dich" : "\(likers.count) Personen mögen dich")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(brand)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(brand.opacity(0.10))
            .clipShape(Capsule())
            .padding(.top, 8)

            if let liker = pendingLiker {
                likerCard(liker)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func likerCard(_ liker: LikerProfile) -> some View {
        let isRevealed = revealedId == liker.userId

        VStack(spacing: 0) {
            // Photo area
            ZStack(alignment: .bottom) {
                likerPhoto(liker, revealed: isRevealed)

                if !isRevealed {
                    // Frosted lock overlay
                    VStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                        if canReveal {
                            Button {
                                reveal(liker)
                            } label: {
                                Text("Enthüllen")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 13)
                                    .background(
                                        LinearGradient(colors: [brand, brandAlt],
                                                       startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Capsule())
                                    .shadow(color: brand.opacity(0.5), radius: 14, y: 6)
                            }
                            .buttonStyle(.plain)
                        } else {
                            VStack(spacing: 4) {
                                Text("Nächste Enthüllung in")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                                Text(countdownText)
                                    .font(.system(.title3, design: .monospaced).weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(isRevealed ? brand.opacity(0.25) : Color.clear, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 20, y: 10)

            // Info & action (only when revealed)
            if isRevealed {
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(liker.displayName)
                                .font(.title2.weight(.bold))
                            if let age = liker.age {
                                Text("\(age)")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let city = liker.city, !city.isEmpty {
                            Label(city, systemImage: "mappin")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 14) {
                        // Pass
                        Button {
                            acted(liker, liked: false)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(.systemBackground))
                                    .shadow(color: Color(.systemGray4).opacity(0.5), radius: 10, y: 4)
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Color(.systemGray2))
                            }
                            .frame(width: 58, height: 58)
                        }

                        // Like back
                        Button {
                            acted(liker, liked: true)
                        } label: {
                            ZStack {
                                Capsule()
                                    .fill(
                                        LinearGradient(colors: [brand, brandAlt],
                                                       startPoint: .leading, endPoint: .trailing)
                                    )
                                    .shadow(color: brand.opacity(0.45), radius: 14, y: 6)
                                HStack(spacing: 8) {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Auch liken")
                                        .font(.headline.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                            }
                            .frame(height: 58)
                        }
                    }
                }
                .padding(.top, 20)
            }
        }
    }

    @ViewBuilder
    private func likerPhoto(_ liker: LikerProfile, revealed: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let url = liker.photoUrl.flatMap({ URL(string: $0) }) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color(.systemGray5).overlay(ProgressView())
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .blur(radius: revealed ? 0 : 22)
                .animation(.easeInOut(duration: 0.4), value: revealed)
            } else {
                ZStack {
                    LinearGradient(colors: [brand.opacity(0.35), brand.opacity(0.15)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "person.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .blur(radius: revealed ? 0 : 18)
            }

            // Gradient
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.65), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(maxWidth: .infinity)
            .frame(height: 380)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Actions

    private func reveal(_ liker: LikerProfile) {
        revealedId = liker.userId
        UserDefaults.standard.set(Date(), forKey: cooldownKey)
    }

    private func acted(_ liker: LikerProfile, liked: Bool) {
        // Save to revealed set
        var ids = UserDefaults.standard.stringArray(forKey: revealedIdsKey) ?? []
        ids.append(liker.userId.uuidString)
        UserDefaults.standard.set(ids, forKey: revealedIdsKey)

        if liked {
            Task { try? await SwipeService.shared.upsertSwipe(swiperId: myId, targetId: liker.userId, isLike: true) }
        }

        // Remove from list and reset revealed
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            likers.removeFirst()
            revealedId = nil
        }

        // Cooldown already set at reveal; start showing countdown for next
        startCountdownTimer()
    }

    // MARK: - Data

    private func loadLikers() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            // 1. Who has liked me
            struct SwipeRow: Decodable {
                let swiper_id: UUID
                let created_at: String?
            }
            let client = SupabaseClientProvider.shared.client
            let liked: [SwipeRow] = try await client
                .from("swipes")
                .select("swiper_id,created_at")
                .eq("target_id", value: myId.uuidString)
                .eq("is_like", value: true)
                .order("created_at", ascending: false)
                .execute()
                .value

            // 2. IDs I've already acted on
            let acted = revealedIds
            let pending = liked.filter { !acted.contains($0.swiper_id) }

            if pending.isEmpty {
                likers = []
                return
            }

            // 3. Load profiles for pending likers
            let ids = pending.prefix(50).map { $0.swiper_id.uuidString }

            struct ProfileRow: Decodable {
                let user_id: UUID
                let display_name: String?
                let bio: String?
                let city: String?
                let birthdate: String?
            }
            struct PhotoRow: Decodable {
                let user_id: UUID
                let url: String
                let is_primary: Bool?
                let sort_order: Int?
            }

            let profiles: [ProfileRow] = try await client
                .from("profiles")
                .select("user_id,display_name,bio,city,birthdate")
                .in("user_id", values: Array(ids))
                .execute()
                .value

            let photos: [PhotoRow] = try await client
                .from("photos")
                .select("user_id,url,is_primary,sort_order")
                .in("user_id", values: Array(ids))
                .order("sort_order", ascending: true)
                .execute()
                .value

            // Build photo map (primary first)
            var photoMap: [UUID: String] = [:]
            for p in photos {
                if p.is_primary == true || photoMap[p.user_id] == nil {
                    photoMap[p.user_id] = p.url
                }
            }

            let profileMap = Dictionary(profiles.map { ($0.user_id, $0) }, uniquingKeysWith: { a, _ in a })

            likers = pending.compactMap { swipe in
                guard let prof = profileMap[swipe.swiper_id] else { return nil }
                return LikerProfile(
                    userId: swipe.swiper_id,
                    displayName: prof.display_name ?? "Unbekannt",
                    photoUrl: photoMap[swipe.swiper_id],
                    bio: prof.bio ?? "",
                    city: prof.city,
                    birthdate: prof.birthdate
                )
            }
        } catch {
            errorText = error.localizedDescription
        }

        startCountdownTimer()
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        guard !canReveal else { return }
        updateCountdown()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
            Task { @MainActor in
                updateCountdown()
                if canReveal { countdownTimer?.invalidate() }
            }
        }
    }

    private func updateCountdown() {
        guard let next = nextRevealDate else { countdownText = ""; return }
        let remaining = next.timeIntervalSince(Date())
        if remaining <= 0 { countdownText = ""; return }
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60
        countdownText = String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Model

struct LikerProfile: Identifiable {
    var id: UUID { userId }
    let userId: UUID
    let displayName: String
    let photoUrl: String?
    let bio: String
    let city: String?
    let birthdate: String?

    var age: Int? {
        guard let bd = birthdate else { return nil }
        let parts = bd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        guard let date = Calendar.current.date(from: comps) else { return nil }
        return Calendar.current.dateComponents([.year], from: date, to: Date()).year
    }
}
