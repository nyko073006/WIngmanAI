//
//  RootView.swift
//  WIngmanAI
//
//  Created by Nyko on 31.01.26.
//

import SwiftUI
import Auth

struct RootView: View {
    @EnvironmentObject var auth: AuthService
    @State private var onboardingComplete: Bool? = nil

    private let onboarding = OnboardingService()

    var body: some View {
        Group {
            if auth.session == nil {
                AuthView()
            } else if onboardingComplete == nil {
                ProgressView()
            } else if onboardingComplete == false {
                OnboardingView(onFinished: {
                    Task {
                        try? await onboarding.setOnboardingComplete(
                            userId: auth.session!.user.id,
                            value: true
                        )
                        onboardingComplete = true
                    }
                })
            } else {
                MainView()
            }
        }
        .task(id: auth.session?.user.id) {
            guard let userId = auth.session?.user.id else {
                onboardingComplete = nil
                return
            }
            do {
                onboardingComplete = try await onboarding.fetchOnboardingComplete(userId: userId)
            } catch {
                onboardingComplete = false
            }
        }
    }
}
