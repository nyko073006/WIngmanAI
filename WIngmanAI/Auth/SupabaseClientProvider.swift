import Foundation
import Supabase

/// Centralized Supabase client configuration.
///
/// Add these keys to your app’s Info.plist:
/// - SUPABASE_URL (e.g. https://xxxx.supabase.co)
/// - SUPABASE_ANON_KEY (sb_publishable_...)
final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()

    let supabaseURL: URL
    let anonKey: String
    let client: SupabaseClient

    private static let fallbackURL = URL(string: "https://invalid.supabase.co")!
    private static let fallbackKey = "invalid-key"

    private init() {
        // Read + sanitize SUPABASE_URL
        let rawURL = (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedURLString: String =
            rawURL.hasPrefix("https://") || rawURL.hasPrefix("http://")
            ? rawURL
            : "https://\(rawURL)"

        if rawURL.isEmpty || URL(string: normalizedURLString)?.host == nil {
            assertionFailure("Missing or invalid SUPABASE_URL in Info.plist")
            self.supabaseURL = Self.fallbackURL
            self.anonKey = Self.fallbackKey
            self.client = SupabaseClient(supabaseURL: Self.fallbackURL, supabaseKey: Self.fallbackKey)
            return
        }
        self.supabaseURL = URL(string: normalizedURLString)!

        let anonKeyRaw = (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if anonKeyRaw.isEmpty {
            assertionFailure("Missing SUPABASE_ANON_KEY in Info.plist")
            self.anonKey = Self.fallbackKey
            self.client = SupabaseClient(supabaseURL: self.supabaseURL, supabaseKey: Self.fallbackKey)
            return
        }
        self.anonKey = anonKeyRaw

        self.client = SupabaseClient(
            supabaseURL: self.supabaseURL,
            supabaseKey: self.anonKey,
            options: .init(
                auth: .init(
                    autoRefreshToken: true,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }
}
