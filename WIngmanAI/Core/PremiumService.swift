//
//  PremiumService.swift
//  WIngmanAI
//

import Foundation
import Combine
import StoreKit
import Supabase

@MainActor
final class PremiumService: ObservableObject {
    static let shared = PremiumService()

    @Published private(set) var currentTier: Tier = .none
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchasing = false
    /// True while the initial DB tier check is in flight — UI can show a spinner instead of paywall.
    @Published private(set) var isTierLoading = true

    enum Tier: String {
        case none, premium, elite

        var isPremium: Bool { self != .none }
        var isElite: Bool { self == .elite }
    }

    private static let premiumIDs: Set<String> = [
        "com.wingmanai.premium.woechentlich",
        "com.wingmanai.premium.monatlich",
        "com.wingmanai.premium.vierteljaehrlich",
        "com.wingmanai.premium.jaehrlich"
    ]
    private static let eliteIDs: Set<String> = [
        "com.wingmanai.elite.woechentlich",
        "com.wingmanai.elite.monatlich",
        "com.wingmanai.elite.vierteljaehrlich",
        "com.wingmanai.elite.halbjaehrlich"
    ]

    var isPremium: Bool { currentTier.isPremium }
    var isElite: Bool { currentTier.isElite }

    var premiumProducts: [Product] {
        products.filter { Self.premiumIDs.contains($0.id) }.sorted { $0.price < $1.price }
    }
    var eliteProducts: [Product] {
        products.filter { Self.eliteIDs.contains($0.id) }.sorted { $0.price < $1.price }
    }

    private let tierKey = "subscription_tier"

    private init() {
        currentTier = Tier(rawValue: UserDefaults.standard.string(forKey: tierKey) ?? "") ?? .none
        // If we already have a cached tier, don't block UI with loading state
        if currentTier != .none { isTierLoading = false }
        Task { await loadProducts() }
        Task {
            await refreshEntitlements()
            await loadTierFromSupabase()
            isTierLoading = false
        }
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.premiumIDs.union(Self.eliteIDs))
        } catch {
            print("PremiumService.loadProducts:", error)
        }
    }

    func purchase(_ product: Product) async throws {
        isPurchasing = true
        defer { isPurchasing = false }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let tx) = verification else { throw PremiumError.verificationFailed }
            await tx.finish()
            updateTier(for: tx.productID)
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements(syncToServer: true)
    }

    /// Call after auth session is established to pick up DB-granted tiers.
    func reloadTier() async {
        isTierLoading = true
        await loadTierFromSupabase()
        isTierLoading = false
    }

    func refreshEntitlements(syncToServer: Bool = false) async {
        var highestTier: Tier = .none
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result, !tx.isUpgraded else { continue }
            if Self.eliteIDs.contains(tx.productID) {
                highestTier = .elite
                break
            } else if Self.premiumIDs.contains(tx.productID) {
                highestTier = .premium
            }
        }
        // Only apply if StoreKit found an active subscription, OR this is an
        // explicit sync (restore/purchase). Without this guard, a cold launch with
        // no StoreKit subscription would overwrite a DB-granted tier with .none.
        if highestTier != .none || syncToServer {
            setTier(highestTier, syncToServer: syncToServer)
        }
    }

    private func updateTier(for productID: String) {
        let newTier: Tier = Self.eliteIDs.contains(productID) ? .elite : .premium
        setTier(newTier, syncToServer: true)
        AnalyticsService.shared.track(.subscriptionStarted, properties: [
            "tier": newTier.rawValue,
            "product_id": productID
        ])
    }

    private func setTier(_ tier: Tier, syncToServer: Bool = false) {
        currentTier = tier
        UserDefaults.standard.set(tier.rawValue, forKey: tierKey)
        // Only sync on real purchase/restore events, not on every app-launch refresh
        if syncToServer {
            Task { await syncTierToSupabase(tier) }
        }
    }

    // Writes the verified tier into profiles.subscription_tier so the
    // consume_ai_credit DB function can enforce the correct daily limit.
    private func syncTierToSupabase(_ tier: Tier) async {
        guard let userID = try? await SupabaseClientProvider.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseClientProvider.shared.client
                .from("profiles")
                .update(["subscription_tier": tier == .none ? "free" : tier.rawValue])
                .eq("user_id", value: userID.uuidString)
                .execute()
        } catch {
            print("PremiumService.syncTierToSupabase:", error)
        }
    }

    /// Reads subscription_tier from Supabase on app launch.
    /// Allows manually setting a tier via the DB (e.g. for testing/gifting).
    /// Only upgrades local tier — StoreKit is still authoritative for downgrades.
    private func loadTierFromSupabase() async {
        guard let userID = try? await SupabaseClientProvider.shared.client.auth.session.user.id else { return }
        struct Row: Decodable { let subscription_tier: String? }
        do {
            let rows: [Row] = try await SupabaseClientProvider.shared.client
                .from("profiles")
                .select("subscription_tier")
                .eq("user_id", value: userID.uuidString)
                .limit(1)
                .execute()
                .value
            guard let tierStr = rows.first?.subscription_tier else { return }
            let dbTier: Tier = {
                switch tierStr {
                case "elite":   return .elite
                case "premium": return .premium
                default:        return .none
                }
            }()
            // Only upgrade — if StoreKit already granted a higher tier, keep it
            if dbTier.isElite || (dbTier.isPremium && !currentTier.isPremium) {
                setTier(dbTier, syncToServer: false)
            }
        } catch {
            print("PremiumService.loadTierFromSupabase:", error)
        }
    }

    enum PremiumError: LocalizedError {
        case verificationFailed
        var errorDescription: String? { "Kauf konnte nicht verifiziert werden." }
    }
}
