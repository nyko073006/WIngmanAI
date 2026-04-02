//
//  ProfileTabView.swift
//  WingmanAI
//

import SwiftUI
import Combine
import Supabase
import PhotosUI
import UIKit

// MARK: - Helpers

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? { self.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

// MARK: - ViewModel

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorText: String?

    // Profile fields
    @Published var displayName = ""
    @Published var bio = ""
    @Published var city = ""
    @Published var birthdate: String?
    @Published var interests: [String] = []
    @Published var firstDateVibes: [String] = []
    @Published var hooks: [String] = []

    // Discovery settings
    @Published var distanceKm: Int = 50
    @Published var ageMin: Int = 18
    @Published var ageMax: Int = 45
    @Published var interestedInArr: [String] = []
    @Published var lookingForStr: String? = nil

    // Boundaries
    @Published var boundaries = BoundaryPreferences()

    // Photos
    @Published var photos: [PhotoRow] = []

    struct PhotoRow: Identifiable, Equatable {
        let id: UUID
        let url: String
        let isPrimary: Bool
        let sortOrder: Int
        let isSnapshot: Bool
    }

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    // Computed age from "YYYY-MM-DD"
    var age: Int? {
        guard let bd = birthdate else { return nil }
        let parts = bd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        guard let birthDate = Calendar.current.date(from: comps) else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
    }

    func load(userId: UUID) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        struct ProfileRow: Decodable {
            let display_name: String?
            let bio: String?
            let city: String?
            let birthdate: String?
            let interests: [String]?
            let first_date_vibes: [String]?
            let hooks: [String]?
            let distance_km: Int?
            let age_min: Int?
            let age_max: Int?
            let interested_in_arr: [String]?
            let looking_for: String?
            let boundaries: BoundaryPreferences?
        }

        struct DBPhotoRow: Decodable {
            let id: UUID
            let url: String
            let is_primary: Bool?
            let sort_order: Int?
            let is_snapshot: Bool?
        }

        do {
            let rows: [ProfileRow] = try await client
                .from("profiles")
                .select("display_name,bio,city,birthdate,interests,first_date_vibes,hooks,distance_km,age_min,age_max,interested_in_arr,looking_for,boundaries")
                .eq("user_id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value

            if let r = rows.first {
                displayName = r.display_name ?? ""
                bio = r.bio ?? ""
                city = r.city ?? ""
                birthdate = r.birthdate
                interests = r.interests ?? []
                firstDateVibes = r.first_date_vibes ?? []
                hooks = r.hooks ?? []
                distanceKm = r.distance_km ?? 50
                ageMin = r.age_min ?? 18
                ageMax = r.age_max ?? 45
                interestedInArr = r.interested_in_arr ?? []
                lookingForStr = r.looking_for
                boundaries = r.boundaries ?? BoundaryPreferences()
            }

            let dbPhotos: [DBPhotoRow] = try await client
                .from("photos")
                .select("id,url,is_primary,sort_order,is_snapshot")
                .eq("user_id", value: userId.uuidString)
                .order("sort_order", ascending: true)
                .execute()
                .value

            photos = dbPhotos.map {
                PhotoRow(id: $0.id, url: $0.url, isPrimary: $0.is_primary ?? false, sortOrder: $0.sort_order ?? 0, isSnapshot: $0.is_snapshot ?? false)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func saveExtended(
        userId: UUID,
        displayName: String,
        bio: String,
        city: String,
        interests: [String],
        firstDateVibes: [String],
        hooks: [String]
    ) async {
        isSaving = true
        defer { isSaving = false }
        do {
            struct FullUpdate: Encodable {
                let display_name: String
                let bio: String
                let city: String
                let interests: [String]
                let first_date_vibes: [String]
                let hooks: [String]
                let updated_at: String
            }
            _ = try await client
                .from("profiles")
                .update(FullUpdate(
                    display_name: displayName, bio: bio, city: city,
                    interests: interests, first_date_vibes: firstDateVibes,
                    hooks: hooks,
                    updated_at: ISO8601DateFormatter().string(from: Date())
                ))
                .eq("user_id", value: userId.uuidString)
                .execute()
            self.displayName = displayName
            self.bio = bio
            self.city = city
            self.interests = interests
            self.firstDateVibes = firstDateVibes
            self.hooks = hooks
        } catch {
            errorText = error.localizedDescription
        }
    }

    func saveBasics(userId: UUID, displayName: String, bio: String, city: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            struct Update: Encodable {
                let display_name: String
                let bio: String
                let city: String
                let updated_at: String
            }
            _ = try await client
                .from("profiles")
                .update(Update(display_name: displayName, bio: bio, city: city, updated_at: ISO8601DateFormatter().string(from: Date())))
                .eq("user_id", value: userId.uuidString)
                .execute()
            self.displayName = displayName
            self.bio = bio
            self.city = city
        } catch {
            errorText = error.localizedDescription
        }
    }

    func saveDiscovery(userId: UUID, distanceKm: Int, ageMin: Int, ageMax: Int, interestedInArr: [String], lookingFor: String?) async {
        isSaving = true
        defer { isSaving = false }
        do {
            struct DiscoveryUpdate: Encodable {
                let distance_km: Int
                let age_min: Int
                let age_max: Int
                let interested_in_arr: [String]
                let looking_for: String?
                let updated_at: String
            }
            _ = try await client
                .from("profiles")
                .update(DiscoveryUpdate(
                    distance_km: distanceKm,
                    age_min: ageMin,
                    age_max: ageMax,
                    interested_in_arr: interestedInArr,
                    looking_for: lookingFor,
                    updated_at: ISO8601DateFormatter().string(from: Date())
                ))
                .eq("user_id", value: userId.uuidString)
                .execute()
            self.distanceKm = distanceKm
            self.ageMin = ageMin
            self.ageMax = ageMax
            self.interestedInArr = interestedInArr
            self.lookingForStr = lookingFor
        } catch {
            errorText = error.localizedDescription
        }
    }

    func saveBoundaries(userId: UUID, boundaries: BoundaryPreferences) async {
        isSaving = true
        defer { isSaving = false }
        struct BoundaryUpdate: Encodable {
            let boundaries: BoundaryPreferences
            let updated_at: String
        }
        do {
            _ = try await client
                .from("profiles")
                .update(BoundaryUpdate(boundaries: boundaries, updated_at: ISO8601DateFormatter().string(from: Date())))
                .eq("user_id", value: userId.uuidString)
                .execute()
            self.boundaries = boundaries
        } catch {
            errorText = error.localizedDescription
        }
    }

    func uploadAndSetPrimary(userId: UUID, item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let compressed = compressJPEG(data) ?? data

        let bucket = "profile-photos"
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let accessToken = SupabaseClientProvider.shared.client.auth.currentSession?.accessToken ?? ""

        do {
            let url = SupabaseClientProvider.shared.supabaseURL
                .appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = compressed
            req.setValue(SupabaseClientProvider.shared.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            req.setValue("true", forHTTPHeaderField: "x-upsert")
            let (uploadData, uploadResp) = try await URLSession.shared.data(for: req)
            if let http = uploadResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: uploadData, encoding: .utf8) ?? ""
                throw NSError(domain: "StorageUpload", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Foto-Upload fehlgeschlagen (\(http.statusCode)). \(body)"])
            }

            let publicUrl = try client.storage.from(bucket).getPublicURL(path: path).absoluteString

            _ = try? await client.from("photos")
                .update(["is_primary": false])
                .eq("user_id", value: userId.uuidString)
                .execute()

            struct PhotoInsert: Encodable {
                let user_id: UUID; let url: String; let sort_order: Int; let is_primary: Bool; let is_snapshot: Bool
            }
            _ = try await client.from("photos")
                .insert(PhotoInsert(user_id: userId, url: publicUrl, sort_order: 0, is_primary: true, is_snapshot: false))
                .execute()

            await load(userId: userId)
        } catch {
            errorText = "Foto-Upload fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func uploadAdditionalPhoto(userId: UUID, item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let compressed = compressJPEG(data) ?? data

        let bucket = "profile-photos"
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let accessToken = SupabaseClientProvider.shared.client.auth.currentSession?.accessToken ?? ""

        do {
            let url = SupabaseClientProvider.shared.supabaseURL
                .appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = compressed
            req.setValue(SupabaseClientProvider.shared.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            req.setValue("true", forHTTPHeaderField: "x-upsert")
            let (uploadData, uploadResp) = try await URLSession.shared.data(for: req)
            if let http = uploadResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: uploadData, encoding: .utf8) ?? ""
                throw NSError(domain: "StorageUpload", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Foto-Upload fehlgeschlagen (\(http.statusCode)). \(body)"])
            }

            let publicUrl = try client.storage.from(bucket).getPublicURL(path: path).absoluteString

            let maxSortOrder = photos.map { $0.sortOrder }.max() ?? -1
            let newSortOrder = maxSortOrder + 1
            let isPrimary = photos.isEmpty // If no photos exist, make this primary

            struct PhotoInsert: Encodable {
                let user_id: UUID; let url: String; let sort_order: Int; let is_primary: Bool; let is_snapshot: Bool
            }
            _ = try await client.from("photos")
                .insert(PhotoInsert(user_id: userId, url: publicUrl, sort_order: newSortOrder, is_primary: isPrimary, is_snapshot: false))
                .execute()

            await load(userId: userId)
        } catch {
            errorText = "Foto-Upload fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func deletePhoto(userId: UUID, photoId: UUID) async {
        do {
            _ = try await client.from("photos")
                .delete()
                .eq("id", value: photoId.uuidString)
                .eq("user_id", value: userId.uuidString)
                .execute()
            photos.removeAll { $0.id == photoId }
            // Promote first remaining photo as primary if needed
            if !photos.isEmpty, !photos.contains(where: { $0.isPrimary }) {
                let firstId = photos[0].id
                _ = try? await client.from("photos")
                    .update(["is_primary": true])
                    .eq("id", value: firstId.uuidString)
                    .execute()
                let p = photos[0]
                photos[0] = PhotoRow(id: p.id, url: p.url, isPrimary: true, sortOrder: p.sortOrder, isSnapshot: p.isSnapshot)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func reorderPhotos(userId: UUID, orderedIds: [UUID]) async {
        // Optimistic update: first photo becomes primary
        photos = orderedIds.enumerated().compactMap { i, id in
            guard let p = photos.first(where: { $0.id == id }) else { return nil }
            return PhotoRow(id: p.id, url: p.url, isPrimary: i == 0, sortOrder: i, isSnapshot: p.isSnapshot)
        }
        // Persist
        for (i, id) in orderedIds.enumerated() {
            struct OrderUpdate: Encodable { let sort_order: Int; let is_primary: Bool }
            _ = try? await client.from("photos")
                .update(OrderUpdate(sort_order: i, is_primary: i == 0))
                .eq("id", value: id.uuidString)
                .eq("user_id", value: userId.uuidString)
                .execute()
        }
    }

    private func compressJPEG(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1200
        let scale = min(1.0, maxSide / max(img.size.width, img.size.height))
        if scale < 1.0 {
            let newSize = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
            return resized.jpegData(compressionQuality: 0.82)
        }
        return img.jpegData(compressionQuality: 0.82)
    }
}

// MARK: - Main View

struct ProfileTabView: View {
    @EnvironmentObject var auth: AppAuthService
    @StateObject private var vm = ProfileViewModel()

    @StateObject private var premium = PremiumService.shared
    @State private var showSubscription = false
    @State private var showEditSheet = false
    @State private var showDiscoverySettings = false
    @State private var showBoundarySettings = false
    @State private var showProfilePreview = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isSigningOut = false
    @State private var showDeleteAccountConfirm = false
    @State private var isDeletingAccount = false
    @State private var showManagePhotos = false

    private let brand = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)

    /// 0.0 – 1.0 completeness score
    private var completeness: Double {
        var score = 0; var total = 0
        total += 1; if !vm.photos.isEmpty { score += 1 }
        total += 1; if vm.photos.count >= 3 { score += 1 }
        total += 1; if !vm.bio.isEmpty { score += 1 }
        total += 1; if !vm.interests.isEmpty { score += 1 }
        total += 1; if vm.firstDateVibes.count >= 2 { score += 1 }
        total += 1; if !vm.hooks.isEmpty { score += 1 }
        total += 1; if !vm.city.isEmpty { score += 1 }
        return total > 0 ? Double(score) / Double(total) : 0
    }

    private var completenessLabel: String {
        switch completeness {
        case 1.0:         return "Perfekt 🔥"
        case 0.85...:     return "Fast fertig 👌"
        case 0.6...:      return "Gut aufgestellt 👍"
        default:          return "Profil vervollständigen"
        }
    }

    private var completenessNextHint: String {
        if vm.photos.isEmpty { return "Füge dein erstes Foto hinzu" }
        if vm.photos.count < 3 { return "Füge \(3 - vm.photos.count) weitere Fotos hinzu" }
        if vm.bio.isEmpty { return "Schreib eine kurze Bio" }
        if vm.city.isEmpty { return "Gib deinen Wohnort an" }
        if vm.interests.isEmpty { return "Wähle deine Interessen" }
        if vm.firstDateVibes.count < 2 { return "Füge First-Date Vibes hinzu" }
        if vm.hooks.isEmpty { return "Füge Gesprächsstarter hinzu" }
        return "Profil ist vollständig!"
    }

    private func boundaryChipLabels(_ b: BoundaryPreferences) -> [String] {
        var chips: [String] = []
        switch b.relationshipGoal {
        case "serious": chips.append("💍 Ernsthaft")
        case "casual": chips.append("🌊 Casual")
        case "friendship": chips.append("🤝 Freundschaft")
        case "open": chips.append("✨ Offen")
        default: break
        }
        for d in b.dealbreakers.prefix(2) {
            switch d {
            case "smoking": chips.append("🚭")
            case "longdistance": chips.append("📍")
            case "kids": chips.append("👶")
            case "alcohol": chips.append("🍺")
            case "pets": chips.append("🐾")
            default: break
            }
        }
        return chips
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            photoHeader
                            profileContent
                        }
                    }
                    .background(Color(.systemGroupedBackground))
                    .refreshable { await reload() }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Image("colored-logo-ohne-schrift")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 32)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showProfilePreview = true
                    } label: {
                        Label("Vorschau", systemImage: "eye")
                    }
                    .tint(brand)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bearbeiten") { showEditSheet = true }
                        .tint(brand)
                }

            }
        }
        .task(id: auth.session?.user.id) { await reload() }
        .onChange(of: photoPickerItem) { _, item in
            guard let item, let userId = auth.session?.user.id else { return }
            Task { await vm.uploadAndSetPrimary(userId: userId, item: item) }
        }
        .sheet(isPresented: $showProfilePreview) {
            if let userId = auth.session?.user.id {
                OtherUserProfileSheet(userId: userId)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let userId = auth.session?.user.id {
                EditProfileSheet(vm: vm, userId: userId, brand: brand)
            }
        }
        .sheet(isPresented: $showDiscoverySettings) {
            if let userId = auth.session?.user.id {
                DiscoverySettingsSheet(vm: vm, userId: userId, brand: brand)
            }
        }
        .sheet(isPresented: $showBoundarySettings) {
            if let userId = auth.session?.user.id {
                BoundarySettingsSheet(userId: userId, current: vm.boundaries) { saved in
                    vm.boundaries = saved
                }
            }
        }
        .sheet(isPresented: $showSubscription) {
            SubscriptionView()
        }
        .sheet(isPresented: $showManagePhotos) {
            if let userId = auth.session?.user.id {
                ManagePhotosSheet(vm: vm, userId: userId, brand: brand)
            }
        }
        .alert("Fehler", isPresented: Binding(get: { vm.errorText != nil }, set: { if !$0 { vm.errorText = nil } })) {
            Button("OK", role: .cancel) { vm.errorText = nil }
        } message: {
            Text(vm.errorText ?? "")
        }
        .alert("Account wirklich löschen?", isPresented: $showDeleteAccountConfirm) {
            Button("Löschen", role: .destructive) {
                Task { await deleteAccountAction() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dein Konto, Profil und alle Daten werden dauerhaft gelöscht. Diese Aktion kann nicht rückgängig gemacht werden.")
        }
    }

    // MARK: Photo header

    private var photoHeader: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = 340
            ZStack(alignment: .bottomLeading) {
                profilePhoto(w: w, h: h)

                LinearGradient(colors: [.clear, .black.opacity(0.60)], startPoint: .center, endPoint: .bottom)
                    .frame(width: w, height: h)
                    .allowsHitTesting(false)

                // Name + age + city
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(vm.displayName.isEmpty ? "Dein Name" : vm.displayName)
                            .font(.title2).fontWeight(.bold).foregroundStyle(.white)
                        if let age = vm.age {
                            Text("\(age)").font(.title3).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    if !vm.city.isEmpty {
                        Label(vm.city, systemImage: "mappin")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .frame(width: w, alignment: .leading)
                .allowsHitTesting(false)

                // Manage Photos button
                Button {
                    showManagePhotos = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Fotos verwalten")
                .padding(16)
                .frame(width: w, alignment: .trailing)
            }
            .frame(width: w, height: h)
        }
        .frame(height: 340)
    }

    @ViewBuilder
    private func profilePhoto(w: CGFloat, h: CGFloat) -> some View {
        let primary = vm.photos.first(where: { $0.isPrimary }) ?? vm.photos.first
        if let urlStr = primary?.url, let url = URL(string: urlStr) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill().frame(width: w, height: h).clipped()
                default:
                    Color(.systemGray5).frame(width: w, height: h).overlay(ProgressView())
                }
            }
        } else {
            ZStack {
                LinearGradient(colors: [brand.opacity(0.3), brand.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "person.fill").font(.system(size: 60)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: w, height: h)
        }
    }

    // MARK: Profile content

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: 20) {

            Spacer(minLength: 20)

            // Completeness banner
            if completeness < 1.0 {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(brand.opacity(0.15), lineWidth: 4)
                            .frame(width: 46, height: 46)
                        Circle()
                            .trim(from: 0, to: completeness)
                            .stroke(
                                LinearGradient(colors: [brand, brand.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 46, height: 46)
                            .animation(.easeOut(duration: 0.8), value: completeness)
                        Text("\(Int(completeness * 100))%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(brand)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completenessLabel)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        Text(completenessNextHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(brand.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(brand.opacity(0.12), lineWidth: 1))
                .onTapGesture { showEditSheet = true }
                .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 24) {

                // Bio
                if !vm.bio.isEmpty {
                    section("Über mich") {
                        Text(vm.bio)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }

                // Interests
                if !vm.interests.isEmpty {
                    section("Interessen") {
                        FlowChips(items: vm.interests, brand: brand)
                    }
                }

                // First date vibes
                if !vm.firstDateVibes.isEmpty {
                    section("First-Date Vibes") {
                        FlowChips(items: vm.firstDateVibes, brand: brand.opacity(0.7))
                    }
                }

                // Hooks
                if !vm.hooks.isEmpty {
                    section("Gesprächsstarter") {
                        FlowChips(items: vm.hooks, brand: brand.opacity(0.6))
                    }
                }

                // Hooks

                // Boundaries
                section("Grenzen & Präferenzen") {
                    Button {
                        showBoundarySettings = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.teal.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.teal)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                if vm.boundaries.relationshipGoal == nil && vm.boundaries.dealbreakers.isEmpty {
                                    Text("Grenzen festlegen")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("Zeig, was du suchst – weniger Missverständnisse")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Grenzen & Präferenzen")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    let chips = boundaryChipLabels(vm.boundaries)
                                    Text(chips.isEmpty ? "Festgelegt" : chips.prefix(2).joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Subscription
                section("Wingman Pro") {
                    if premium.isPremium {
                        Button { showSubscription = true } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(brand.opacity(0.12))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "crown.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(brand)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(premium.isElite ? "Elite aktiv" : "Premium aktiv")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Tippen zum Verwalten oder Upgraden")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(brand)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { showSubscription = true } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(brand.opacity(0.12))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "crown.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(brand)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wingman Pro freischalten")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Unbegrenzte AI · Likes sehen · Mehr")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Discovery settings
                section("Sucheinstellungen") {
                    Button {
                        showDiscoverySettings = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Radius & Alter · Ich suche")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(vm.distanceKm) km · \(vm.ageMin)–\(vm.ageMax) Jahre")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Account
                section("Account") {
                    if let email = auth.session?.user.email {
                        Label(email, systemImage: "envelope")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let url = URL(string: "https://wingmanapp.de/datenschutz") {
                        Link(destination: url) {
                            Label("Datenschutzerklärung", systemImage: "hand.raised")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }

                    if let url = URL(string: "https://wingmanapp.de/agb") {
                        Link(destination: url) {
                            Label("AGB & Nutzungsbedingungen", systemImage: "doc.text")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                    Button {
                        Task { await signOut() }
                    } label: {
                        if isSigningOut {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.85)
                                Text("Abmelden…")
                                    .font(.subheadline)
                            }
                        } else {
                            Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(isSigningOut)

                    Button(role: .destructive) {
                        showDeleteAccountConfirm = true
                    } label: {
                        if isDeletingAccount {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.85)
                                Text("Account wird gelöscht…")
                                    .font(.subheadline)
                            }
                        } else {
                            Label("Account löschen", systemImage: "trash")
                                .font(.subheadline)
                        }
                    }
                    .disabled(isDeletingAccount)
                }

            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }

    // MARK: Actions

    private func reload() async {
        guard let userId = auth.session?.user.id else { return }
        await vm.load(userId: userId)
    }

    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        await auth.signOut()
    }

    private func deleteAccountAction() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        await auth.deleteAccount()
    }
}

// MARK: - Edit Sheet

private struct EditProfileSheet: View {
    @ObservedObject var vm: ProfileViewModel
    let userId: UUID
    let brand: Color

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var city: String = ""
    @State private var selectedInterests: Set<String> = []
    @State private var selectedVibes: Set<String> = []
    @State private var selectedHooks: Set<String> = []
    @State private var aiGeneratedHooks: [String] = []
    @State private var aiGeneratedVibes: [String] = []
    @State private var isGeneratingAI: Bool = false

    private let interestOptions = [
        "Reisen", "Fitness", "Kochen", "Musik", "Filme",
        "Natur", "Kaffee", "Bücher", "Tanzen", "Wandern",
        "Wein", "Yoga", "Reiten", "Gaming", "Kunst"
    ]
    private let vibeOptions = [
        "Kaffee & ehrliche Gespräche", "Abendspaziergang mit Snacks",
        "Sonnenuntergang-Spot", "Flohmarkt-Date",
        "Food-Date", "Picknick im Park",
        "Museum / Galerie", "Buchladen stöbern",
        "Kletterpark-Challenge", "Escape-Room",
        "City-Walk", "Fahrrad-Runde",
        "Eis & Talk", "Cocktailbar",
        "Koch-Date", "Streetfood-Tour",
        "Kino + Diskussion danach", "Minigolf",
        "Roadtrip ins Grüne", "Berg-View"
    ]
    private let hookOptions = [
        "Ich rate deinen Vibe am Lieblingssong.",
        "Ich hab eine Playlist für jeden Stimmungstyp – welcher bist du?",
        "Ich kann dir in 30 Sekunden sagen, ob ein Café was taugt.",
        "Ich bin Team Deep Talk statt Small Talk.",
        "Meine Green Flag: Klartext reden.",
        "Ich hab immer einen unpassenden Witz parat.",
        "Ich beurteile Restaurants daran, wie sie Wasser nachfüllen.",
        "Mein erstes Date-Urteil: Wie jemand mit dem Servicepersonal umgeht.",
        "Ich sammle die besten schlechten Filmempfehlungen.",
        "Ich hab zu vielen Dingen eine Meinung – auch zu Ketchup."
    ]

    var body: some View {
        NavigationStack {
            Form {
                // Photos
                Section {
                    NavigationLink {
                        ManagePhotosSheet(vm: vm, userId: userId, brand: brand)
                    } label: {
                        Label("Fotos verwalten", systemImage: "photo.stack")
                            .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Fotos")
                } footer: {
                    Text("Füge neue Fotos hinzu oder ändere die Reihenfolge.")
                }

                // Basics
                Section("Name") {
                    TextField("Anzeigename", text: $name)
                }
                Section("Stadt") {
                    TextField("z.B. Ulm", text: $city)
                }
                Section("Bio") {
                    TextEditor(text: $bio).frame(minHeight: 90)
                }

                // Interests
                Section {
                    EditChipGrid(options: interestOptions, selected: $selectedInterests, brand: brand)
                } header: {
                    Text("Interessen")
                } footer: {
                    Text("\(selectedInterests.count) ausgewählt")
                }

                // AI generate button
                Section {
                    Button {
                        Task { await generateAISuggestions() }
                    } label: {
                        HStack(spacing: 10) {
                            if isGeneratingAI {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(brand)
                            }
                            Text(isGeneratingAI ? "KI generiert…" : "Wingman-AI nach Vorschlägen fragen")
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(isGeneratingAI ? .secondary : brand)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isGeneratingAI)
                } footer: {
                    Text("Passend zu deiner Bio, Interessen & Stadt.")
                }

                // Vibes
                Section {
                    EditChipGrid(
                        options: aiGeneratedVibes + vibeOptions.filter { !aiGeneratedVibes.contains($0) },
                        selected: $selectedVibes,
                        brand: brand,
                        aiItems: Set(aiGeneratedVibes)
                    )
                } header: {
                    Text("First-Date Vibes")
                } footer: {
                    Text("\(selectedVibes.count) ausgewählt · ✦ = KI-Vorschlag")
                }

                // Hooks
                Section {
                    EditChipGrid(
                        options: aiGeneratedHooks + hookOptions.filter { !aiGeneratedHooks.contains($0) },
                        selected: $selectedHooks,
                        brand: brand,
                        aiItems: Set(aiGeneratedHooks)
                    )
                } header: {
                    Text("Gesprächsstarter")
                } footer: {
                    Text("Am besten 2–3 wählen · \(selectedHooks.count) ausgewählt")
                }

            }
            .navigationTitle("Profil bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Speichern") {
                        Task {
                            await vm.saveExtended(
                                userId: userId,
                                displayName: name, bio: bio, city: city,
                                interests: Array(selectedInterests).sorted(),
                                firstDateVibes: Array(selectedVibes).sorted(),
                                hooks: Array(selectedHooks).sorted()
                            )
                            if vm.errorText == nil { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                    .tint(brand)
                    .disabled(vm.isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
            }
            .overlay { if vm.isSaving { ProgressView() } }
        }
        .onAppear { populate() }
    }

    private func generateAISuggestions() async {
        isGeneratingAI = true
        defer { isGeneratingAI = false }

        let input = HooksInput(
            gender: nil,
            interestedIn: vm.interestedInArr.isEmpty ? nil : vm.interestedInArr,
            city: city.nilIfEmpty,
            lookingFor: vm.lookingForStr,
            bio: bio.nilIfEmpty,
            interests: Array(selectedInterests),
            promptAnswers: nil,
            maxHooks: 8,
            maxVibes: 8
        )

        do {
            let result = try await AIService.shared.generateHooks(input: input)
            aiGeneratedHooks = result.hooks
            aiGeneratedVibes = result.firstDateVibes
            for hook in result.hooks.prefix(3) { selectedHooks.insert(hook) }
            for vibe in result.firstDateVibes.prefix(4) { selectedVibes.insert(vibe) }
        } catch {
            vm.errorText = "AI Fehler: \(error.localizedDescription)"
            print("AI Generate error: \(error)")
        }
    }

    private func populate() {
        name = vm.displayName
        bio = vm.bio
        city = vm.city
        selectedInterests = Set(vm.interests)
        selectedVibes = Set(vm.firstDateVibes)
        selectedHooks = Set(vm.hooks)
    }
}

// MARK: - Chip picker for Edit Sheet

private struct EditChipGrid: View {
    let options: [String]
    @Binding var selected: Set<String>
    let brand: Color
    var aiItems: Set<String> = []

    var body: some View {
        _FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(options, id: \.self) { option in
                let isOn = selected.contains(option)
                let isAI = aiItems.contains(option)
                Button {
                    if isOn { selected.remove(option) }
                    else { selected.insert(option) }
                } label: {
                    HStack(spacing: 4) {
                        if isAI {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.semibold))
                        }
                        Text(option)
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .background(isOn ? brand.opacity(0.15) : Color(.systemGray6))
                    .foregroundStyle(isOn ? brand : (isAI ? brand.opacity(0.7) : .secondary))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(isOn ? brand.opacity(0.4) : (isAI ? brand.opacity(0.25) : Color.clear), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Photo Grid Editor

// MARK: - Flow Chips

private struct FlowChips: View {
    let items: [String]
    let brand: Color

    var body: some View {
        _FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .background(brand.opacity(0.10))
                    .foregroundStyle(brand)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct _FlowLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 0
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for s in subviews {
            let natural = s.sizeThatFits(.unspecified)
            let chipW = min(natural.width, maxW)
            let chipH = natural.width > maxW
                ? s.sizeThatFits(ProposedViewSize(width: maxW, height: nil)).height
                : natural.height
            if x > 0, x + chipW > maxW { x = 0; y += rowH + rowSpacing; rowH = 0 }
            x += (x > 0 ? spacing : 0) + chipW
            rowH = max(rowH, chipH)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for s in subviews {
            let natural = s.sizeThatFits(.unspecified)
            let chipW = min(natural.width, maxW)
            let chipH = natural.width > maxW
                ? s.sizeThatFits(ProposedViewSize(width: maxW, height: nil)).height
                : natural.height
            if x > bounds.minX, x + chipW > bounds.maxX { x = bounds.minX; y += rowH + rowSpacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: chipW, height: chipH))
            x += chipW + spacing; rowH = max(rowH, chipH)
        }
    }
}

// MARK: - Discovery Settings Sheet

private struct DiscoverySettingsSheet: View {
    @ObservedObject var vm: ProfileViewModel
    let userId: UUID
    let brand: Color
    @Environment(\.dismiss) private var dismiss

    @State private var distance: Double = 50
    @State private var ageMin: Double = 18
    @State private var ageMax: Double = 45
    @State private var interested: Set<String> = []
    @State private var lookingFor: Set<String> = []

    private let interestedOptions: [(key: String, label: String, icon: String)] = [
        ("women", "Frauen", "figure.stand.dress"),
        ("men", "Männer", "figure.stand"),
        ("divers", "Divers", "person.2.wave.2")
    ]
    private let lookingForOptions: [(key: String, label: String, icon: String)] = [
        ("serious", "Etwas Ernstes", "heart.fill"),
        ("casual", "Etwas Lockeres", "sparkles"),
        ("friends", "Neue Freunde", "person.2.fill"),
        ("open_to_all", "Bin offen", "infinity")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Radius", systemImage: "location.circle")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(distance)) km")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brand)
                        }
                        Slider(value: $distance, in: 5...150, step: 5)
                            .tint(brand)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Entfernung")
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Min. Alter", systemImage: "person")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Stepper("\(Int(ageMin))", value: $ageMin, in: 18...Double(ageMax), step: 1)
                                .labelsHidden()
                            Text("\(Int(ageMin))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brand)
                                .frame(width: 28, alignment: .trailing)
                        }
                        HStack {
                            Label("Max. Alter", systemImage: "person.fill")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Stepper("\(Int(ageMax))", value: $ageMax, in: Double(ageMin)...99, step: 1)
                                .labelsHidden()
                            Text("\(Int(ageMax))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brand)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Altersbereich")
                }

                Section {
                    HStack(spacing: 10) {
                        ForEach(interestedOptions, id: \.key) { opt in
                            let isOn = interested.contains(opt.key)
                            Button {
                                if isOn { interested.remove(opt.key) }
                                else { interested.insert(opt.key) }
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: opt.icon)
                                        .font(.system(size: 22, weight: .medium))
                                    Text(opt.label)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                                .foregroundStyle(isOn ? .white : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    isOn
                                    ? AnyShapeStyle(LinearGradient(colors: [brand, brand.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(Color(.systemGray6))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(isOn ? brand.opacity(0.0) : Color(.systemGray4).opacity(0.4), lineWidth: 1)
                                )
                                .shadow(color: isOn ? brand.opacity(0.3) : .clear, radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Ich suche")
                }

                Section {
                    HStack(spacing: 10) {
                        ForEach(lookingForOptions, id: \.key) { opt in
                            let isOn = lookingFor.contains(opt.key)
                            Button {
                                lookingFor = isOn ? [] : [opt.key]
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: opt.icon)
                                        .font(.system(size: 22, weight: .medium))
                                    Text(opt.label)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .foregroundStyle(isOn ? .white : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    isOn
                                    ? AnyShapeStyle(LinearGradient(colors: [brand, brand.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(Color(.systemGray6))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(isOn ? Color.clear : Color(.systemGray4).opacity(0.4), lineWidth: 1)
                                )
                                .shadow(color: isOn ? brand.opacity(0.3) : .clear, radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Was suchst du?")
                }
            }
            .navigationTitle("Sucheinstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Speichern") {
                        Task {
                            let lf = lookingFor.isEmpty ? nil : lookingFor.sorted().joined(separator: ",")
                            await vm.saveDiscovery(
                                userId: userId,
                                distanceKm: Int(distance),
                                ageMin: Int(ageMin),
                                ageMax: Int(ageMax),
                                interestedInArr: Array(interested).sorted(),
                                lookingFor: lf
                            )
                            if vm.errorText == nil { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                    .tint(brand)
                    .disabled(vm.isSaving)
                }
            }
            .overlay { if vm.isSaving { ProgressView() } }
        }
        .onAppear { populate() }
    }

    private func populate() {
        distance = Double(vm.distanceKm)
        ageMin = Double(vm.ageMin)
        ageMax = Double(vm.ageMax)
        interested = Set(vm.interestedInArr)
        if let lf = vm.lookingForStr, !lf.isEmpty {
            lookingFor = Set(lf.split(separator: ",").map { String($0) })
        }
    }
}

// MARK: - Other User Profile Sheet

@MainActor
final class OtherUserProfileViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorText: String?

    @Published var displayName = ""
    @Published var bio = ""
    @Published var city = ""
    @Published var birthdate: String?
    @Published var interests: [String] = []
    @Published var firstDateVibes: [String] = []
    @Published var hooks: [String] = []
    @Published var photoUrls: [String] = []
    @Published var lastActiveAt: Date?
    @Published var boundaries = BoundaryPreferences()

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    var activityLabel: String? {
        guard let date = lastActiveAt else { return nil }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) {
            return now.timeIntervalSince(date) < 300 ? "Gerade aktiv" : "Aktiv heute"
        } else if cal.isDateInYesterday(date) {
            return "Aktiv gestern"
        }
        return nil
    }

    var age: Int? {
        guard let bd = birthdate else { return nil }
        let parts = bd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        guard let birthDate = Calendar.current.date(from: comps) else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
    }

    func load(userId: UUID) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        struct ProfileRow: Decodable, Sendable {
            let display_name: String?
            let bio: String?
            let city: String?
            let birthdate: String?
            let interests: [String]?
            let first_date_vibes: [String]?
            let hooks: [String]?
            let last_active_at: Date?
            let boundaries: BoundaryPreferences?
        }
        struct DBPhotoRow: Decodable, Sendable {
            let url: String; let is_primary: Bool?; let sort_order: Int?
        }

        do {
            async let rowsTask: [ProfileRow] = client
                .from("profiles")
                .select("display_name,bio,city,birthdate,interests,first_date_vibes,hooks,last_active_at,boundaries")
                .eq("user_id", value: userId.uuidString)
                .limit(1).execute().value

            async let dbPhotosTask: [DBPhotoRow] = client
                .from("photos")
                .select("url,is_primary,sort_order")
                .eq("user_id", value: userId.uuidString)
                .order("sort_order", ascending: true).execute().value
                
            let (rows, dbPhotos) = try await (rowsTask, dbPhotosTask)

            if let r = rows.first {
                displayName = r.display_name ?? ""
                bio = r.bio ?? ""
                city = r.city ?? ""
                birthdate = r.birthdate
                interests = r.interests ?? []
                firstDateVibes = r.first_date_vibes ?? []
                hooks = r.hooks ?? []
                lastActiveAt = r.last_active_at
                boundaries = r.boundaries ?? BoundaryPreferences()
            }

            let sorted = dbPhotos.sorted { a, b in
                if (a.is_primary ?? false) != (b.is_primary ?? false) { return a.is_primary ?? false }
                return (a.sort_order ?? 0) < (b.sort_order ?? 0)
            }
            photoUrls = sorted.map { $0.url }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct OtherUserProfileSheet: View {
    let userId: UUID
    var distanceKm: Int? = nil
    var isEmbedded: Bool = false

    @StateObject private var vm = OtherUserProfileViewModel()
    @Environment(\.dismiss) private var dismiss

    private let brand = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)
    @State private var photoIndex = 0

    var body: some View {
        Group {
            if isEmbedded {
                mainContent
            } else {
                NavigationStack {
                    mainContent
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Schließen") { dismiss() }.tint(brand)
                            }
                        }
                }
            }
        }
        .task { await vm.load(userId: userId) }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        Group {
            if vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(40)
            } else if let err = vm.errorText {
                VStack(spacing: 10) {
                    Text(err).multilineTextAlignment(.center).font(.footnote)
                    Button("Erneut") { Task { await vm.load(userId: userId) } }
                }
                .padding().frame(maxWidth: .infinity, alignment: .center)
            } else {
                if isEmbedded {
                    VStack(spacing: 0) {
                        photoHeader
                        profileContent
                    }
                    .background(Color(.systemGroupedBackground))
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            photoHeader
                            profileContent
                        }
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
        }
    }

    // MARK: Photo header

    private var photoHeader: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = 420
            ZStack(alignment: .bottom) {
                photoGallery(w: w, h: h)

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.80), location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: w, height: h)
                .allowsHitTesting(false)

                if vm.photoUrls.count > 1 {
                    VStack {
                        HStack(spacing: 5) {
                            ForEach(0..<vm.photoUrls.count, id: \.self) { i in
                                Capsule()
                                    .fill(i == photoIndex ? Color.white : Color.white.opacity(0.45))
                                    .frame(width: i == photoIndex ? 18 : 6, height: 4)
                                    .animation(.easeInOut(duration: 0.2), value: photoIndex)
                            }
                        }
                        .padding(.top, 14)
                        Spacer()
                    }
                    .frame(width: w, height: h)
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(vm.displayName.isEmpty ? "Unbekannt" : vm.displayName)
                            .font(.title).fontWeight(.bold).foregroundStyle(.white)
                        if let age = vm.age {
                            Text("\(age)").font(.title2).foregroundStyle(.white.opacity(0.82))
                        }
                    }
                    HStack(spacing: 10) {
                        if !vm.city.isEmpty {
                            Label(vm.city, systemImage: "mappin")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                        if let km = distanceKm {
                            Text(km < 1 ? "< 1 km" : "\(km) km")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.70))
                        }
                        if let label = vm.activityLabel {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(label == "Gerade aktiv" ? Color.green : Color.white.opacity(0.55))
                                    .frame(width: 6, height: 6)
                                Text(label)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.80))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
                .frame(width: w, alignment: .leading)
                .allowsHitTesting(false)

                if vm.photoUrls.count > 1 {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: w * 0.4, height: h)
                            .contentShape(Rectangle())
                            .onTapGesture { if photoIndex > 0 { photoIndex -= 1 } }
                        Spacer()
                        Color.clear
                            .frame(width: w * 0.4, height: h)
                            .contentShape(Rectangle())
                            .onTapGesture { if photoIndex < vm.photoUrls.count - 1 { photoIndex += 1 } }
                    }
                    .frame(width: w, height: h)
                }
            }
            .frame(width: w, height: h)
        }
        .frame(height: 420)
    }

    @ViewBuilder
    private func photoGallery(w: CGFloat, h: CGFloat) -> some View {
        let url = vm.photoUrls.indices.contains(photoIndex) ? URL(string: vm.photoUrls[photoIndex]) : nil
        if let url {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill().frame(width: w, height: h).clipped()
                case .empty:
                    Color(.systemGray5).frame(width: w, height: h).overlay(ProgressView())
                case .failure:
                    Color(.systemGray5).frame(width: w, height: h)
                        .overlay(Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary))
                }
            }
        } else {
            ZStack {
                LinearGradient(colors: [brand.opacity(0.3), brand.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "person.fill").font(.system(size: 72)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: w, height: h)
        }
    }

    // MARK: Profile content

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !vm.bio.isEmpty {
                contentSection("Über mich") {
                    Text(vm.bio)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !vm.interests.isEmpty {
                contentSection("Interessen") {
                    FlowChips(items: vm.interests, brand: brand)
                }
            }
            if !vm.hooks.isEmpty {
                contentSection("Gesprächsstarter") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.hooks, id: \.self) { hook in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(brand)
                                    .frame(width: 3)
                                Text(hook)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if !vm.firstDateVibes.isEmpty {
                contentSection("First Date Vibes") {
                    FlowChips(items: vm.firstDateVibes, brand: brand.opacity(0.7))
                }
            }

            let boundaryChips = makeBoundaryChips(vm.boundaries)
            if !boundaryChips.isEmpty {
                contentSection("Grenzen & Präferenzen") {
                    FlowChips(items: boundaryChips, brand: Color(.systemTeal).opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 48)
    }

    private func makeBoundaryChips(_ b: BoundaryPreferences) -> [String] {
        var chips: [String] = []
        switch b.relationshipGoal {
        case "serious":    chips.append("💍 Ernsthafte Beziehung")
        case "casual":     chips.append("🌊 Casual & offen")
        case "friendship": chips.append("🤝 Freundschaft first")
        case "open":       chips.append("✨ Mal schauen")
        default: break
        }
        switch b.commStyle {
        case "texter":   chips.append("💬 Viel schreiben")
        case "balanced": chips.append("⚖️ Ausgewogen")
        case "caller":   chips.append("📞 Lieber reden")
        default: break
        }
        for d in b.dealbreakers {
            switch d {
            case "smoking":      chips.append("🚭 Kein Rauchen")
            case "longdistance": chips.append("📍 Keine Fernbeziehung")
            case "kids":         chips.append("👶 Kinder no-go")
            case "alcohol":      chips.append("🍺 Kein Alkohol")
            case "pets":         chips.append("🐾 Keine Haustiere")
            default: break
            }
        }
        return chips
    }

    private func contentSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }
}

// MARK: - Manage Photos Sheet

struct ManagePhotosSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: ProfileViewModel
    let userId: UUID
    let brand: Color

    @State private var photoPickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(vm.photos) { photo in
                        HStack(spacing: 16) {
                            if let url = URL(string: photo.url) {
                                CachedAsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill().frame(width: 60, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                                    default:
                                        Color(.systemGray5).frame(width: 60, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            } else {
                                Color(.systemGray5).frame(width: 60, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                if photo.isPrimary || vm.photos.first?.id == photo.id {
                                    Text("Hauptbild")
                                        .font(.caption.bold())
                                        .foregroundStyle(brand)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Text("Zusätzliches Bild")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .font(.title3)
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { indices, newOffset in
                        var newPhotos = vm.photos
                        newPhotos.move(fromOffsets: indices, toOffset: newOffset)
                        Task {
                            await vm.reorderPhotos(userId: userId, orderedIds: newPhotos.map { $0.id })
                        }
                    }
                    .onDelete { indices in
                        for idx in indices {
                            let photoId = vm.photos[idx].id
                            Task {
                                await vm.deletePhoto(userId: userId, photoId: photoId)
                            }
                        }
                    }
                } footer: {
                    Text("Das oberste Bild wird als dein Hauptprofilbild angezeigt. Halte gedrückt und ziehe an den 3 Linien, um die Reihenfolge zu ändern. Wische nach links, um ein Bild zu löschen.")
                        .font(.caption)
                }

                if vm.photos.count < 6 {
                    Section {
                        PhotosPicker(selection: $photoPickerItem, matching: .images) {
                            HStack {
                                Spacer()
                                Label("Neues Foto hinzufügen", systemImage: "plus.circle.fill")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(brand)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fotos verwalten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
            .onChange(of: photoPickerItem) { _, item in
                guard let item else { return }
                Task {
                    vm.isLoading = true
                    await vm.uploadAdditionalPhoto(userId: userId, item: item)
                    vm.isLoading = false
                    photoPickerItem = nil
                }
            }
            .overlay {
                if vm.isLoading {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView()
                        .padding(24)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}
