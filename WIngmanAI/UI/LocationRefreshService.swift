import CoreLocation
import Foundation
import Supabase
import PostgREST

@MainActor
final class LocationRefreshService {
    static let shared = LocationRefreshService()
    private let manager = CLLocationManager()
    private let cooldownSeconds: TimeInterval = 30 * 60
    private let lastRefreshKey = "location_last_refresh_at"
    private init() {}

    func refreshIfAuthorized(userId: UUID) async {
        guard #available(iOS 17.0, *) else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }

        let lastRefresh = UserDefaults.standard.double(forKey: lastRefreshKey)
        let elapsed = Date().timeIntervalSince1970 - lastRefresh
        guard elapsed >= cooldownSeconds else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRefreshKey)

        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                guard let loc = update.location else { continue }
                let lat = loc.coordinate.latitude
                let lng = loc.coordinate.longitude
                struct Loc: Encodable { let location_lat: Double; let location_lng: Double }
                _ = try? await SupabaseClientProvider.shared.client
                    .from("profiles")
                    .update(Loc(location_lat: lat, location_lng: lng))
                    .eq("user_id", value: userId.uuidString)
                    .execute()
                break
            }
        } catch {
            // Location update unavailable — fail silently
        }
    }
}
