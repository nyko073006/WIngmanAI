import CoreLocation
import Foundation

@MainActor
final class LocationRefreshService {
    static let shared = LocationRefreshService()
    private init() {}

    func refreshIfAuthorized(userId: UUID) async {
        guard #available(iOS 17.0, *) else { return }
        let mgr = CLLocationManager()
        let status = mgr.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }

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
