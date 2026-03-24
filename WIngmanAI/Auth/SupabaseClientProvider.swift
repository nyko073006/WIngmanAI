import Foundation
import Supabase

/// Central place to configure and access the Supabase client used across the app.
///
/// TODO: Replace the placeholder `supabaseURL` and `supabaseAnonKey` with your project's values.
/// You can keep them in a configuration plist or environment if preferred.
final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()

    /// The shared Supabase client instance.
    let client: SupabaseClient

    private init() {
        // TODO: Replace with your real Supabase URL and anon key.
        let supabaseURL = URL(string: "https://YOUR-PROJECT-REF.supabase.co")!
        let supabaseAnonKey = "YOUR-ANON-KEY"

        self.client = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseAnonKey
        )
    }
}
