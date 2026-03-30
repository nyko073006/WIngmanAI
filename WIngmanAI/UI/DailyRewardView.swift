//
//  DailyRewardView.swift
//  WIngmanAI
//

import SwiftUI

struct DailyRewardView: View {

    enum BoxState { case idle, shaking, exploding, revealed }

    @StateObject private var rewardService = DailyRewardService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var boxState: BoxState = .idle
    @State private var shakeOffset: CGFloat = 0
    @State private var boxScale: CGFloat = 1
    @State private var boxOpacity: Double = 1
    @State private var glowRadius: CGFloat = 20
    @State private var item1Offset: CGFloat = 60
    @State private var item1Opacity: Double = 0
    @State private var item2Offset: CGFloat = 60
    @State private var item2Opacity: Double = 0
    @State private var streakBadgeScale: CGFloat = 0
    @State private var claimedReward: DailyRewardService.Reward? = nil
    @State private var burstOpacity: Double = 0

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(.systemBackground), Theme.brand.opacity(0.08)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Burst rays (revealed state)
            BurstView()
                .foregroundStyle(Theme.brand.opacity(0.12))
                .opacity(burstOpacity)
                .ignoresSafeArea()

            VStack(spacing: boxState == .revealed ? 16 : 28) {
                Spacer()

                // Streak badge
                streakBadge
                    .scaleEffect(streakBadgeScale)

                // The Box
                ZStack {
                    // Glow
                    Circle()
                        .fill(Theme.brand.opacity(0.15))
                        .frame(width: boxState == .revealed ? 100 : 160, height: boxState == .revealed ? 100 : 160)
                        .blur(radius: glowRadius)

                    // Box emoji
                    Text(boxState == .revealed ? "✨" : "🎁")
                        .font(.system(size: boxState == .revealed ? 60 : 90))
                        .offset(x: shakeOffset)
                        .scaleEffect(boxScale)
                        .opacity(boxOpacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: shakeOffset)
                        .animation(.spring(response: 0.4, dampingFraction: 0.5), value: boxScale)
                }
                .frame(height: boxState == .revealed ? 80 : 160)

                // Title
                VStack(spacing: 4) {
                    Text(boxState == .revealed ? "Daily Reward abgeholt!" : "Daily Reward")
                        .font(.system(boxState == .revealed ? .title3 : .title2, design: .rounded).weight(.bold))
                    Text(boxState == .revealed
                         ? "Deine Credits wurden gutgeschrieben."
                         : "Tag \(rewardService.currentStreak + 1) Streak · täglich öffnen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Reward items (appear after opening)
                if boxState == .revealed, let reward = claimedReward {
                    HStack(spacing: 12) {
                        rewardItem(icon: "sparkles",
                                   value: "+\(reward.aiCredits)",
                                   label: "AI-Credits",
                                   color: Theme.brand)
                        .offset(y: item1Offset)
                        .opacity(item1Opacity)

                        let altColor = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)
                        rewardItem(icon: "hand.draw.fill",
                                   value: "+\(reward.bonusSwipes)",
                                   label: "Bonus Swipes",
                                   color: altColor)
                        .offset(y: item2Offset)
                        .opacity(item2Opacity)
                    }

                    if reward.isJackpot {
                        Text("🎉 Jackpot! 7-Tage-Streak!")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.brand)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Theme.brand.opacity(0.12))
                            .clipShape(Capsule())
                            .offset(y: item2Offset)
                            .opacity(item2Opacity)
                    }
                }

                Spacer()

                // CTA
                actionButton

                // 7-day strip
                weekStrip
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Streak Badge

    private var streakBadge: some View {
        HStack(spacing: 6) {
            Text("🔥")
                .font(.system(size: 18))
            Text("Tag \(boxState == .revealed ? rewardService.currentStreak : rewardService.currentStreak + 1)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.brand)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.brand.opacity(0.1))
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.3)) {
                streakBadgeScale = 1
            }
        }
    }

    // MARK: - Reward Item

    private func rewardItem(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 56, height: 56)
                    .blur(radius: 12)
                
                Circle()
                    .fill(
                        LinearGradient(colors: [color.opacity(0.2), color.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 56, height: 56)
                    .overlay(Circle().stroke(color.opacity(0.3), lineWidth: 1))
                
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [color, color.opacity(0.7)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            .padding(.bottom, 2)
            
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.5))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThickMaterial)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(colors: [color.opacity(0.5), color.opacity(0.1), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5
                )
        )
        .shadow(color: color.opacity(0.15), radius: 20, y: 10)
    }

    // MARK: - Week Strip

    private var weekStrip: some View {
        HStack(spacing: 8) {
            ForEach(1...7, id: \.self) { day in
                let streakMod = boxState == .revealed
                    ? rewardService.currentStreak % 7
                    : rewardService.currentStreak % 7
                let completed = day <= streakMod
                let current = day == streakMod + 1 && boxState != .revealed

                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(completed ? Theme.brand : (current ? Theme.brand.opacity(0.3) : Color(.systemGray5)))
                            .frame(width: 28, height: 28)
                        if day == 7 {
                            Text("🎁").font(.system(size: 11))
                        } else {
                            Image(systemName: completed ? "checkmark" : "\(day).circle.fill")
                                .font(.system(size: completed ? 11 : 9, weight: .bold))
                                .foregroundStyle(completed ? .white : Color(.systemGray3))
                        }
                    }
                    Text("T\(day)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(current ? Theme.brand : .secondary)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(
            ZStack {
                Capsule().fill(Color(.systemBackground).opacity(0.4))
                Capsule().fill(.ultraThinMaterial)
            }
        )
        .overlay(
            Capsule().stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Group {
            if boxState == .revealed {
                Button { dismiss() } label: { ctaLabel("Schließen") }
                    .buttonStyle(.plain)
            } else {
                Button { openBox() } label: { ctaLabel("Öffnen 🎁") }
                    .buttonStyle(.plain)
                    .disabled(boxState != .idle)
            }
        }
    }

    private func ctaLabel(_ text: String) -> some View {
        let altColor = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)
        return Text(text)
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(colors: [Theme.brand, altColor],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
            .shadow(color: Theme.brand.opacity(0.3), radius: 10, y: 4)
    }

    // MARK: - Animation Sequence

    private func openBox() {
        boxState = .shaking

        // 1. Shake
        let shakes: [(CGFloat, Double)] = [(-14,0), (14,0.08), (-10,0.16), (10,0.24), (-6,0.32), (0,0.40)]
        for (offset, delay) in shakes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                shakeOffset = offset
            }
        }

        // 2. Glow pulse
        withAnimation(.easeInOut(duration: 0.4)) { glowRadius = 50 }

        // 3. Explode box
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            boxState = .exploding
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                boxScale = 1.4
            }
            withAnimation(.easeIn(duration: 0.25).delay(0.15)) {
                boxOpacity = 0
            }
        }

        // 4. Claim & reveal items
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let reward = rewardService.claim()
            claimedReward = reward
            boxState = .revealed

            withAnimation(.easeOut(duration: 0.2)) { burstOpacity = 1 }
            withAnimation(.easeInOut(duration: 1.5).delay(0.5)) { burstOpacity = 0 }

            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                item1Offset = 0; item1Opacity = 1
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.12)) {
                item2Offset = 0; item2Opacity = 1
            }
        }
    }
}

// MARK: - Burst Shape

private struct BurstView: View {
    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let rays = 12
            ForEach(0..<rays, id: \.self) { i in
                let angle = Double(i) / Double(rays) * .pi * 2
                Rectangle()
                    .frame(width: 2, height: geo.size.height * 0.6)
                    .offset(y: -geo.size.height * 0.3)
                    .rotationEffect(.radians(angle), anchor: .bottom)
                    .position(center)
            }
        }
    }
}

#Preview {
    DailyRewardView()
        .presentationDetents([.medium])
}
