import Combine
import Foundation
import Supabase
import Auth


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
        self.session = client.auth.currentSession
        self.user = self.session?.user

        // If we do have a session, try to refresh/validate it.
        // If refresh fails, we keep the existing session and only surface non-"missing session" errors.
        if self.session != nil {
            do {
                let refreshed = try await client.auth.session
                self.session = refreshed
                self.user = refreshed.user
            } catch {
                let msg = error.localizedDescription.lowercased()
                if !(msg.contains("session") && (msg.contains("missing") || msg.contains("not found"))) {
                    self.error = AppError(
                        title: "Session aktualisieren fehlgeschlagen",
                        message: error.localizedDescription
                    )
                }
            }
        }

        // Update last_active_at so other users see a fresh timestamp
        if self.session != nil {
            await updateLastActive()
        }
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
            self.session = response.session
            self.user = response.user

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
            self.session = session
            self.user = session.user
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
            self.session = nil
            self.user = nil
        } catch {
            self.error = AppError(title: "Sign Out fehlgeschlagen", message: error.localizedDescription)
        }
    }

    func deleteAccount() async {
        isBusy = true
        defer { isBusy = false }

        guard let accessToken = client.auth.currentSession?.accessToken else {
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
            self.session = nil
            self.user = nil
        } catch {
            self.error = AppError(title: "Account löschen fehlgeschlagen", message: error.localizedDescription)
        }
    }
}
