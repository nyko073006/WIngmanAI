//
//  PublicProfile.swift
//  WingmanAI
//
//  Created by Nyko on 09.02.26.
//

import Foundation

struct PublicProfile: Decodable, Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let city: String?
    let bio: String
    let interests: [String]
    let birthdate: String?
    var distanceKm: Int?
    var lastActiveAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case displayName = "display_name"
        case city
        case bio
        case interests
        case birthdate
        case distanceKm = "distance_km"
        case lastActiveAt = "last_active_at"
    }

    var activityLabel: String? {
        guard let date = lastActiveAt else { return nil }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) {
            return now.timeIntervalSince(date) < 300 ? "Gerade aktiv" : "Aktiv heute"
        } else if cal.isDateInYesterday(date) {
            return "Aktiv gestern"
        }
        return nil
    }
}
