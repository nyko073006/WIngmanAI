//
//  BoostView.swift
//  WingmanAI
//
//  Sheet shown when the user taps "Boost" in the Discover tab.
//

import SwiftUI

struct BoostView: View {
    @EnvironmentObject var auth: AppAuthService
    @StateObject private var boost = BoostService.shared
    @StateObject private var premium = PremiumService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showSubscription = false
    @State private var isActivating = false

    private let brand = Color(.sRGB, red: 0xE8/255, green: 0x60/255, blue: 0x7A/255, opacity: 1)
    private let orange = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                icon
                    .padding(.bottom, 24)
                title
                    .padding(.bottom, 8)
                subtitle
                    .padding(.bottom, 32)
                statusCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                actionButton
                    .padding(.horizontal, 24)
                Spacer()
            }
            .navigationTitle("Wingman Boost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") { dismiss() }
                        .tint(brand)
                }
            }
            .sheet(isPresented: $showSubscription) {
                SubscriptionView()
            }
            .alert("Fehler", isPresented: Binding(
                get: { boost.errorText != nil },
                set: { if !$0 { boost.errorText = nil } }
            )) {
                Button("OK", role: .cancel) { boost.errorText = nil }
            } message: {
                Text(boost.errorText ?? "")
            }
        }
    }

    // MARK: - Subviews

    private var icon: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(colors: [brand.opacity(0.2), orange.opacity(0.1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 100, height: 100)
            Image(systemName: "bolt.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [brand, orange], startPoint: .top, endPoint: .bottom)
                )
        }
    }

    private var title: some View {
        Text(boost.isBoostActive ? "Boost läuft!" : "Sichtbarkeit boosten")
            .font(.title2.bold())
    }

    private var subtitle: some View {
        Text(boost.isBoostActive
             ? "Dein Profil erscheint gerade an erster Stelle bei anderen Usern."
             : "Für 30 Minuten erscheinst du bei anderen Usern ganz vorne. Mehr Swipes, mehr Matches.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    private var statusCard: some View {
        VStack(spacing: 16) {
            if boost.isBoostActive {
                activeCountdown
            } else {
                slotsInfo
            }
        }
        .padding(20)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var activeCountdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 8) {
                Text(boost.remainingFormatted)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(colors: [brand, orange], startPoint: .leading, endPoint: .trailing)
                    )
                Text("verbleibend")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ProgressView(value: boost.remainingSeconds, total: BoostService.durationSeconds)
            .tint(brand)
    }

    @ViewBuilder
    private var slotsInfo: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(1, UsageLimitService.shared.current.boostsPerWeek), id: \.self) { i in
                Circle()
                    .fill(i < boost.weeklySlotsRemaining ? brand : Color(.systemGray4))
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 4)
            }
        }

        Text(boost.weeklySlotsRemaining == 0
             ? "Diese Woche keine Boosts mehr übrig"
             : "\(boost.weeklySlotsRemaining) Boost\(boost.weeklySlotsRemaining == 1 ? "" : "s") diese Woche verfügbar")
            .font(.subheadline.weight(.medium))

        Text("Resets jeden Montag")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var actionButton: some View {
        Group {
            if boost.isBoostActive {
                Label("Boost aktiv", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(.systemGray3))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if !premium.isPremium {
                Button {
                    showSubscription = true
                } label: {
                    Label("Premium für Boosts freischalten", systemImage: "crown.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(colors: [brand, orange], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            } else if boost.weeklySlotsRemaining == 0 {
                Text("Komme nächste Woche wieder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Button {
                    guard let userId = auth.session?.user.id else { return }
                    isActivating = true
                    Task {
                        await boost.activate(userId: userId)
                        isActivating = false
                        if boost.isBoostActive { dismiss() }
                    }
                } label: {
                    Group {
                        if isActivating {
                            ProgressView().tint(.white)
                        } else {
                            Label("Boost aktivieren", systemImage: "bolt.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [brand, orange], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: brand.opacity(0.4), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(isActivating)
            }
        }
    }
}
