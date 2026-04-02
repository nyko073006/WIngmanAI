//
//  WIngmanAIApp.swift
//  WIngmanAI
//
//  Created by Nyko on 31.01.26.
//

import SwiftUI
import Supabase
import UserNotifications
import UIKit
import CoreLocation
import GoogleSignIn

@main
struct WingmanAIApp: App {
    @StateObject private var auth = AppAuthService()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(auth)
                .tint(Theme.brand)
                // Push: request permission + register after login
                .task(id: auth.session?.user.id) {
                    guard auth.session != nil else { return }
                    await PushService.shared.requestPermissionAndRegister()
                }
                // Push: save token to DB
                .onReceive(NotificationCenter.default.publisher(for: .didReceiveAPNSToken)) { note in
                    guard let token = note.object as? String else { return }
                    guard let userId = auth.session?.user.id else { return }
                    Task { await PushService.shared.saveDeviceToken(userId: userId, token: token) }
                }
                // Foreground: refresh activity timestamp + location
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, let userId = auth.session?.user.id else { return }
                    Task {
                        await auth.updateLastActive()
                        await LocationRefreshService.shared.refreshIfAuthorized(userId: userId)
                    }
                }
        }
    }
}
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}


enum Theme {
    static let brand = Color(hex: 0xE8607A)
    static let brandSoft = Color(hex: 0xE8607A, alpha: 0.14)
}

// MARK: - Local Notifications (in-app → background trigger)

@MainActor
final class LocalNotificationHelper {
    static let shared = LocalNotificationHelper()
    private init() {}

    func scheduleNewMessage(from name: String, text: String, matchId: UUID) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = text.isEmpty ? "Neue Nachricht" : text
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "msg-\(matchId.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Step 6 Push Notifications (APNs)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Google Sign In — client ID aus Info.plist (GOOGLE_CLIENT_ID key)
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        return true
    }

    // Google Sign In OAuth callback
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    // Called when user taps a notification while app is in background / killed
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let matchIdString = userInfo["matchId"] as? String,
           let matchId = UUID(uuidString: matchIdString) {
            Task { @MainActor in
                PushService.shared.pendingMatchId = matchId
            }
        }
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: .didReceiveAPNSToken, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs register failed:", error.localizedDescription)
    }
}

extension Notification.Name {
    static let didReceiveAPNSToken = Notification.Name("didReceiveAPNSToken")
}

@MainActor
@Observable
final class PushService {
    static let shared = PushService()
    private init() {}

    var pendingMatchId: UUID? = nil

    func requestPermissionAndRegister() async {
        do {
            let center = UNUserNotificationCenter.current()
            let ok = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            guard ok else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            print("Push permission failed:", error.localizedDescription)
        }
    }

    private struct DeviceUpsert: Encodable {
        let user_id: UUID
        let platform: String
        let token: String
    }

    func saveDeviceToken(userId: UUID, token: String) async {
        do {
            _ = try await SupabaseClientProvider.shared.client
                .from("user_devices")
                .upsert(DeviceUpsert(user_id: userId, platform: "ios", token: token), onConflict: "platform,token")
                .execute()
        } catch {
            print("saveDeviceToken failed:", error.localizedDescription)
        }
    }
}

