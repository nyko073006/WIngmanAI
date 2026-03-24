//
//  WIngmanAIApp.swift
//  WIngmanAI
//
//  Created by Nyko on 31.01.26.
//

import SwiftUI
import Auth 

@main
struct WingmanApp: App {
    @StateObject private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .task {
                    await auth.restoreSession()
                }
        }
    }
}
