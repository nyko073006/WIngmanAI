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

    @StateObject private var premium = PremiumService.shared
    @State private var showSubscription = false
    @State private var isLoading = false
    @State private var likers: [LikerProfile] = []
    @State private var revealedId: UUID? = nil
    @State private var countdownText: String = ""
    @State private var countdownTimer: Timer? = nil
    @State private var errorText: String? = nil

    private let brand    = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)
    private let brandAlt = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)

    // UserDefaults keys
    private let cooldownKey      = "likes_last_reveal_date"
    private let revealedIdsKey   = "likes_revealed_ids"
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
                        Button("Erneut versuchen") {
                            errorText = nil
                            Task { await loadLikers() }
                        }
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
        .sheet(isPresented: $showSubscription) { SubscriptionView() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()

            // Layered glow icon
            ZStack {
                Circle()
                    .fill(brand.opacity(0.06))
                    .frame(width: 200, height: 200)
                Circle()
                    .fill(brand.opacity(0.10))
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(
                        LinearGradient(colors: [brand.opacity(0.22), brandAlt.opacity(0.14)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "heart.slash.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [brand, brandAlt],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .accessibilityLabel("Keine Likes")
            }
            .padding(.bottom, 36)

            Text("Noch keine Likes")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .padding(.bottom, 10)

            Text("Sei aktiv und like andere Profile –\ndann kommen die Likes zu dir.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Liker Content

    private var likerContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Count pill
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(brand)
                    Text(likers.count == 1
                         ? "1 Person mag dich"
                         : "\(likers.count) Personen mögen dich")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(brand)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(brand.opacity(0.10))
                .clipShape(Capsule())
                .padding(.top, 8)

                if let liker = pendingLiker {
                    likerCard(liker)
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: - Liker Card

    @ViewBuilder
    private func likerCard(_ liker: LikerProfile) -> some View {
        let isRevealed = revealedId == liker.userId

        VStack(spacing: 0) {
            // ── Card ──────────────────────────────────────────────────────────
            ZStack(alignment: .bottom) {
                likerPhoto(liker, revealed: isRevealed)

                if isRevealed {
                    // Name / age / city badge on card
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(liker.displayName)
                                .font(.system(.title, design: .rounded).weight(.bold))
                                .foregroundStyle(.white)
                            if let age = liker.age {
                                Text("\(age)")
                                    .font(.title2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.80))
                            }
                        }
                        if let city = liker.city, !city.isEmpty {
                            Label(city, systemImage: "mappin.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 26)

                } else {
                    // Glassmorphism lock overlay
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)

                        VStack(spacing: 22) {
                            // Glowing lock
                            ZStack {
                                Circle()
                                    .fill(brand.opacity(0.30))
                                    .frame(width: 80, height: 80)
                                    .blur(radius: 20)
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 38, weight: .bold))
                                    .foregroundStyle(
                                        LinearGradient(colors: [brand, brandAlt],
                                                       startPoint: .top, endPoint: .bottom)
                                    )
                            }

                            if canReveal {
                                VStack(spacing: 6) {
                                    Text("Wer mag dich?")
                                        .font(.system(.headline, design: .rounded).weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text("Tippe um das Profil zu enthüllen")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Button { reveal(liker) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "sparkles")
                                        Text("Enthüllen")
                                    }
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 38)
                                    .padding(.vertical, 15)
                                    .background(
                                        LinearGradient(colors: [brand, brandAlt],
                                                       startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Capsule())
                                    .shadow(color: brand.opacity(0.55), radius: 20, y: 8)
                                }
                                .buttonStyle(.plain)

                            } else {
                                VStack(spacing: 16) {
                                    VStack(spacing: 6) {
                                        Text("Nächste Enthüllung in")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Text(countdownText)
                                            .font(.system(.title, design: .monospaced).weight(.bold))
                                            .foregroundStyle(.primary)
                                    }

                                    if !premium.isPremium {
                                        Button { showSubscription = true } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "crown.fill")
                                                    .font(.caption.weight(.bold))
                                                Text("Sofort mit Premium")
                                                    .font(.subheadline.weight(.semibold))
                                            }
                                            .foregroundStyle(brand)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 11)
                                            .background(brand.opacity(0.10))
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule().stroke(brand.opacity(0.28), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 490)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 14)

            // ── Action buttons (revealed only) ────────────────────────────────
            if isRevealed {
                HStack(spacing: 14) {
                    // Pass
                    Button { acted(liker, liked: false) } label: {
                        ZStack {
                            Circle()
                                .fill(Color(.systemBackground))
                                .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color(.systemGray3))
                        }
                        .frame(width: 64, height: 64)
                    }
                    .accessibilityLabel("Ablehnen")
                    .buttonStyle(.plain)

                    // Like back
                    Button { acted(liker, liked: true) } label: {
                        ZStack {
                            Capsule()
                                .fill(
                                    LinearGradient(colors: [brand, brandAlt],
                                                   startPoint: .leading, endPoint: .trailing)
                                )
                                .shadow(color: brand.opacity(0.52), radius: 20, y: 8)
                            HStack(spacing: 8) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                Text("Auch liken")
                                    .font(.headline.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                        }
                        .frame(height: 64)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 22)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Photo Layer

    @ViewBuilder
    private func likerPhoto(_ liker: LikerProfile, revealed: Bool) -> some View {
        ZStack {
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
                .frame(height: 490)
                .blur(radius: revealed ? 0 : 28)
                .animation(.easeInOut(duration: 0.45), value: revealed)
            } else {
                ZStack {
                    LinearGradient(colors: [brand.opacity(0.40), brandAlt.opacity(0.20)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "person.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .blur(radius: revealed ? 0 : 20)
            }

            // Bottom gradient for readability when revealed
            if revealed {
                LinearGradient(
                    stops: [
                        .init(color: .clear,              location: 0.40),
                        .init(color: .black.opacity(0.78), location: 1.00)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(maxWidth: .infinity)
                .frame(height: 490)
                .allowsHitTesting(false)
            }
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
            let usageLimits = UsageLimitService.shared
            let isoFormatter = ISO8601DateFormatter()

            var query = client
                .from("swipes")
                .select("swiper_id,created_at")
                .eq("target_id", value: myId.uuidString)
                .eq("is_like", value: true)

            // Likes-Sichtfenster je nach Tier anwenden
            if let windowDate = usageLimits.likesWindowDate {
                query = query.gte("created_at", value: isoFormatter.string(from: windowDate))
            }

            let liked: [SwipeRow] = try await query
                .order("created_at", ascending: false)
                .execute().value

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

            async let profilesTask: [ProfileRow] = client
                .from("profiles")
                .select("user_id,display_name,bio,city,birthdate")
                .in("user_id", values: Array(ids))
                .execute()
                .value

            async let photosTask: [PhotoRow] = client
                .from("photos")
                .select("user_id,url,is_primary,sort_order")
                .in("user_id", values: Array(ids))
                .eq("is_snapshot", value: false)
                .order("sort_order", ascending: true)
                .execute()
                .value

            let (profiles, photos) = try await (profilesTask, photosTask)

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
