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

    private init() {
        // Read + sanitize SUPABASE_URL
        let rawURL = (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If someone pasted without scheme, fix it.
        let normalizedURLString: String =
            rawURL.hasPrefix("https://") || rawURL.hasPrefix("http://")
            ? rawURL
            : "https://\(rawURL)"

        guard
            !rawURL.isEmpty,
            let url = URL(string: normalizedURLString),
            url.host != nil
        else {
            fatalError("Missing/invalid SUPABASE_URL in Info.plist")
        }

        self.supabaseURL = url

        guard
            let anonKeyRaw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
        else {
            fatalError("Missing SUPABASE_ANON_KEY in Info.plist")
        }

        let anonKey = anonKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anonKey.isEmpty else {
            fatalError("Missing SUPABASE_ANON_KEY in Info.plist")
        }

        self.anonKey = anonKey

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
