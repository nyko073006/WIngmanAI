//
//  SubscriptionView.swift
//  WIngmanAI
//

import SwiftUI
import StoreKit

struct SubscriptionView: View {

    enum PlanTier { case premium, elite }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var service = PremiumService.shared
    @State private var selectedTier: PlanTier = .elite   // default to elite since that's what we offer everyone
    @State private var premiumProduct: Product?
    @State private var eliteProduct: Product?
    @State private var errorMessage: String?
    @State private var showError = false

    private let eliteColor = Color(.sRGB, red: 0xF5/255.0, green: 0x9E/255.0, blue: 0x0B/255.0, opacity: 1.0)

    private var selectedProduct: Product? {
        selectedTier == .premium ? premiumProduct : eliteProduct
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        headerSection
                        if service.isPremium { activeBanner }
                        freeCard
                        premiumCard
                        eliteCard
                        if !service.products.isEmpty {
                            ctaButton
                        }
                        manageSection
                        legalText
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 48)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color(.tertiaryLabel))
                            .accessibilityLabel("Schließen")
                    }
                }
            }
            .alert("Fehler", isPresented: $showError, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { msg in Text(msg) }
            .task {
                if service.products.isEmpty { await service.loadProducts() }
                premiumProduct = service.premiumProducts.first { $0.id.contains("monatlich") }
                    ?? service.premiumProducts.first
                eliteProduct = service.eliteProducts.first { $0.id.contains("monatlich") }
                    ?? service.eliteProducts.first
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            Text("Wähle deinen Plan")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Mehr Matches. Mehr Chancen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }

    // MARK: - Cards

    private var freeCard: some View {
        FreeCardView(isCurrentPlan: !service.isPremium)
    }

    private var premiumCard: some View {
        TierCardView(
            name: "Premium",
            icon: "premium-logo",
            accentColor: Theme.brand,
            features: [
                ("hand.draw.fill",       "50 Swipes pro Tag"),
                ("sparkles",             "25 AI-Credits pro Tag"),
                ("eye",                  "Likes: 12h Sichtfenster"),
                ("arrow.uturn.backward", "10 Rewinds pro Tag"),
                ("bolt.fill",            "1 Boost pro Woche"),
                ("eye.slash.fill",       "Inkognito-Modus"),
            ],
            products: service.premiumProducts,
            selectedProduct: $premiumProduct,
            badge: nil,
            isActive: selectedTier == .premium
        ) {
            withAnimation(.spring(duration: 0.25)) { selectedTier = .premium }
        }
    }

    private var eliteCard: some View {
        TierCardView(
            name: "Elite",
            icon: "elite-logo",
            accentColor: eliteColor,
            features: [
                ("hand.draw.fill",       "Unbegrenzte Swipes"),
                ("sparkles",             "50 AI-Credits pro Tag"),
                ("heart.fill",           "Alle Likes sofort sehen"),
                ("arrow.uturn.backward", "Unbegrenzte Rewinds"),
                ("bolt.fill",            "3 Boosts pro Woche"),
                ("eye.slash.fill",       "Inkognito-Modus"),
            ],
            products: service.eliteProducts,
            selectedProduct: $eliteProduct,
            badge: "EMPFOHLEN",
            isActive: selectedTier == .elite
        ) {
            withAnimation(.spring(duration: 0.25)) { selectedTier = .elite }
        }
    }

    // MARK: - Active Banner

    private var activeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.isElite ? "Elite aktiv" : "Premium aktiv")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Text("Abo läuft · wird über Apple abgerechnet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.3), lineWidth: 1))
    }

    // MARK: - CTA

    private var ctaButton: some View {
        let isElite = selectedTier == .elite
        let alreadyActive = (selectedTier == .premium && service.currentTier == .premium)
                         || (selectedTier == .elite   && service.currentTier == .elite)
                         || (selectedTier == .premium && service.currentTier == .elite)
        let isUpgrade = selectedTier == .elite && service.currentTier == .premium
        let accent: Color = isElite ? eliteColor : Theme.brand
        let eliteAltColor = Color(.sRGB, red: 0xF9/255.0, green: 0x73/255.0, blue: 0x16/255.0, opacity: 1.0)
        let brandAltColor = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)
        let gradientColors: [Color] = isElite
            ? [eliteColor, eliteAltColor]
            : [Theme.brand, brandAltColor]
        let label: String = {
            if alreadyActive { return "Bereits aktiv" }
            if isUpgrade     { return "Auf Elite upgraden" }
            return isElite ? "Elite freischalten" : "Premium freischalten"
        }()

        return Button {
            guard let product = selectedProduct, !alreadyActive else { return }
            Task { await purchase(product) }
        } label: {
            ZStack {
                Group {
                    if alreadyActive {
                        Color(.secondarySystemBackground)
                    } else {
                        LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing)
                            .shadow(color: accent.opacity(0.35), radius: 12, y: 5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if service.isPurchasing {
                    ProgressView().tint(Color.white)
                } else {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(alreadyActive ? Color(.secondaryLabel) : Color.white)
                        if let p = selectedProduct, !alreadyActive {
                            Text("• \(p.displayPrice)")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
            .frame(height: 56)
        }
        .buttonStyle(.plain)
        .disabled(service.isPurchasing || selectedProduct == nil || alreadyActive)
    }

    // MARK: - Manage + Restore

    private var manageSection: some View {
        VStack(spacing: 12) {
            if service.isPremium {
                Button {
                    openURL(URL(string: "itms-apps://apps.apple.com/account/subscriptions")!)
                } label: {
                    HStack(spacing: 6) {
                        Text("Abonnement verwalten / kündigen")
                            .font(.footnote.weight(.medium))
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .accessibilityLabel("")
                    }
                    .foregroundStyle(Theme.brand)
                }
                .accessibilityLabel("Abonnement verwalten oder kündigen öffnet Apple App Store")
            }
            // Hide restore if already elite (DB-granted or purchased)
            if !service.isElite {
                Button { Task { await restore() } } label: {
                    Text("Kauf wiederherstellen")
                        .font(.footnote)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
        }
    }

    private var legalText: some View {
        Text("Das Abonnement verlängert sich automatisch, sofern es nicht mindestens 24 Stunden vor Ende des aktuellen Zeitraums gekündigt wird. Die Abrechnung erfolgt über deinen Apple-Account.")
            .font(.caption2)
            .foregroundStyle(Color(.tertiaryLabel))
            .multilineTextAlignment(.center)
    }

    // MARK: - Actions

    private func purchase(_ product: Product) async {
        do {
            try await service.purchase(product)
            if service.isPremium { dismiss() }
        } catch {
            errorMessage = localizedStoreKitError(error)
            showError = true
        }
    }

    private func restore() async {
        do {
            try await service.restorePurchases()
            if service.isPremium { dismiss() }
        } catch {
            errorMessage = localizedStoreKitError(error)
            showError = true
        }
    }

    private func localizedStoreKitError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("unable to complete") || msg.contains("cannot connect") || msg.contains("network") {
            return "Der App Store ist gerade nicht erreichbar. Überprüfe deine Internetverbindung und versuche es erneut."
        }
        if msg.contains("cancel") {
            return "Kauf abgebrochen."
        }
        if msg.contains("not allowed") || msg.contains("restricted") {
            return "Käufe sind auf diesem Gerät nicht erlaubt."
        }
        return error.localizedDescription
    }
}

// MARK: - FreeCardView

private struct FreeCardView: View {
    let isCurrentPlan: Bool

    private let features: [(icon: String, label: String)] = [
        ("hand.draw.fill",       "25 Swipes pro Tag"),
        ("sparkles",             "10 AI-Credits pro Tag"),
        ("eye",                  "Likes: 6h Sichtfenster"),
        ("arrow.uturn.backward", "3 Rewinds pro Tag"),
        ("bubble.left",          "Nachrichten senden"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray5))
                        .frame(width: 64, height: 64)
                    Image(systemName: "person.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color(.systemGray2))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Free")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Kostenlos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isCurrentPlan {
                    Text("AKTUELL")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray2))
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                ForEach(features, id: \.label) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(.systemGray2))
                            .frame(width: 22)
                        Text(feature.label)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                }
            }
        }
        .padding(22)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isCurrentPlan ? Color(.systemGray3) : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - TierCardView

private struct TierCardView: View {
    let name: String
    let icon: String
    let accentColor: Color
    let features: [(icon: String, label: String)]
    let products: [Product]
    @Binding var selectedProduct: Product?
    let badge: String?
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 20) {
                topRow
                featureList
                if !products.isEmpty {
                    durationPills
                }
            }
            .padding(22)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isActive ? accentColor : Color.clear, lineWidth: 2)
            )
            .shadow(color: isActive ? accentColor.opacity(0.18) : .black.opacity(0.04), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                if let p = selectedProduct {
                    Text("\(p.displayPrice) / \(periodLabel(for: p))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accentColor)
                    .clipShape(Capsule())
            }

            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isActive ? accentColor : Color(.systemGray4))
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(features, id: \.label) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 22)
                    Text(feature.label)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private var durationPills: some View {
        HStack(spacing: 8) {
            ForEach(products, id: \.id) { product in
                let isSelected = selectedProduct?.id == product.id
                Button {
                    withAnimation(.spring(duration: 0.2)) {
                        selectedProduct = product
                        onTap()
                    }
                } label: {
                    VStack(spacing: 3) {
                        Text(periodLabel(for: product))
                            .font(.system(size: 12, weight: .semibold))
                        Text(product.displayPrice)
                            .font(.system(size: 13, weight: .bold))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(isSelected ? accentColor : Color(.tertiarySystemBackground))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.clear : Color(.systemGray5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func periodLabel(for product: Product) -> String {
        if product.id.contains("woechentlich") { return "Woche" }
        if product.id.contains("monatlich") { return "Monat" }
        if product.id.contains("vierteljaehrlich") { return "3 Mon." }
        return "6 Mon."
    }
}

#Preview {
    SubscriptionView()
}
