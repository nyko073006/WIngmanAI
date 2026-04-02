import Combine
import Foundation
import Supabase
import Auth
import AuthenticationServices
import GoogleSignIn
import UIKit


@MainActor
final class AppAuthService: ObservableObject {
    // Public state
    @Published private(set) var session: Session?
    @Published private(set) var user: User?
    @Published var isBusy: Bool = false
    @Published var error: AppError?

    var isAuthenticated: Bool { session != nil }

    // Supabase client
    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    /// Public read-only access to the configured Supabase client.
    /// Views can use this for database queries.
    var supabase: SupabaseClient { client }

    // Load any persisted session and user into memory.
    func bootstrap(from url: URL? = nil) async {
        // Clear any previous error
        self.error = nil

        // Handle deep link / magic link / OAuth redirect if provided
        if let url {
            do {
                _ = try await client.auth.session(from: url)
            } catch {
                // This is a real processing error (invalid link etc.)
                self.error = AppError(
                    title: "Session-Verarbeitung fehlgeschlagen",
                    message: error.localizedDescription
                )
            }
        }

        // IMPORTANT:
        // A missing session on fresh install / logged-out state is NORMAL.
        // So we first read the optional in-memory/local session without throwing.
        setSession(client.auth.currentSession)

        // Always attempt async refresh — currentSession may be nil synchronously
        // even when a valid session exists in the Keychain (SDK loads it async).
        do {
            let refreshed = try await client.auth.session
            setSession(refreshed)
        } catch {
            let msg = error.localizedDescription.lowercased()
            if !(msg.contains("session") && (msg.contains("missing") || msg.contains("not found"))) {
                self.error = AppError(
                    title: "Session aktualisieren fehlgeschlagen",
                    message: error.localizedDescription
                )
            }
        }

        // Update last_active_at so other users see a fresh timestamp
        if self.session != nil {
            await updateLastActive()
        }
    }

    /// Single point of truth for session changes — always syncs AIService token.
    private func setSession(_ s: Session?) {
        self.session = s
        self.user = s?.user
        // AIService fetches the token dynamically now.
    }

    func updateLastActive() async {
        guard let userId = session?.user.id else { return }
        struct Update: Encodable { let last_active_at: String }
        _ = try? await client
            .from("profiles")
            .update(Update(last_active_at: ISO8601DateFormatter().string(from: Date())))
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    // MARK: - Auth actions

    func signUp(email: String, password: String) async {
        guard !email.isEmpty, !password.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await client.auth.signUp(email: email, password: password)

            // If email confirmation is ON, session is often nil here.
            setSession(response.session)

            if response.session == nil {
                self.error = AppError(
                    title: "Bestätige deine E-Mail",
                    message: "Ich hab dir eine Mail geschickt. Erst nach Bestätigung kannst du dich einloggen."
                )
            }
        } catch {
            self.error = AppError(title: "Sign Up fehlgeschlagen", message: error.localizedDescription)
        }
    }

    func signIn(email: String, password: String) async {
        guard !email.isEmpty, !password.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let session = try await client.auth.signIn(email: email, password: password)
            setSession(session)
        } catch {
            self.error = AppError(title: "Sign In fehlgeschlagen", message: error.localizedDescription)
        }
    }

    func resetPassword(email: String) async {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.auth.resetPasswordForEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
            self.error = AppError(
                title: "E-Mail gesendet",
                message: "Falls ein Account mit dieser Adresse existiert, schicken wir dir einen Reset-Link."
            )
        } catch {
            self.error = AppError(title: "Fehler", message: error.localizedDescription)
        }
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await client.auth.signOut()
            setSession(nil)
        } catch {
            self.error = AppError(title: "Sign Out fehlgeschlagen", message: error.localizedDescription)
        }
    }

    // MARK: - Google Sign In

    func signInWithGoogle() async {
        isBusy = true
        error = nil
        defer { isBusy = false }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            self.error = AppError(title: "Google Sign In fehlgeschlagen", message: "Kein Root-View gefunden.")
            return
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            guard let idToken = result.user.idToken?.tokenString else {
                self.error = AppError(title: "Google Sign In fehlgeschlagen", message: "Kein ID Token erhalten.")
                return
            }
            let accessToken = result.user.accessToken.tokenString
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .google, idToken: idToken, accessToken: accessToken)
            )
            setSession(session)
        } catch {
            let nsErr = error as NSError
            // GIDSignInErrorCodeCanceled = -5
            guard nsErr.code != -5 else { return }
            self.error = AppError(title: "Google Sign In fehlgeschlagen", message: error.localizedDescription)
        }
    }

    // MARK: - Apple Sign In

    func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let err):
            if let authErr = err as? ASAuthorizationError, authErr.code == .canceled { return }
            self.error = AppError(title: "Apple Sign In fehlgeschlagen", message: err.localizedDescription)

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                self.error = AppError(title: "Apple Sign In fehlgeschlagen", message: "Kein Identity Token erhalten.")
                return
            }

            isBusy = true
            error = nil
            defer { isBusy = false }

            do {
                let session = try await client.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken)
                )
                setSession(session)

                // Apple only sends full name on first sign-in
                if let fullName = credential.fullName {
                    let parts = [fullName.givenName, fullName.familyName].compactMap { $0 }
                    let name = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        struct NameUpdate: Encodable { let display_name: String }
                        _ = try? await client
                            .from("profiles")
                            .update(NameUpdate(display_name: name))
                            .eq("user_id", value: session.user.id.uuidString)
                            .execute()
                    }
                }
            } catch {
                self.error = AppError(title: "Apple Sign In fehlgeschlagen", message: error.localizedDescription)
            }
        }
    }

    func deleteAccount() async {
        isBusy = true
        defer { isBusy = false }

        let session = try? await client.auth.session
        guard let accessToken = session?.accessToken else {
            self.error = AppError(title: "Account löschen fehlgeschlagen", message: "Keine aktive Session.")
            return
        }

        do {
            try await client.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(
                    headers: ["Authorization": "Bearer \(accessToken)"]
                )
            )
            setSession(nil)
        } catch {
            self.error = AppError(title: "Account löschen fehlgeschlagen", message: error.localizedDescription)
        }
    }
}


