//
//  DiscoverProfilesParams.swift
//  WingmanAI
//
//  Created by Nyko on 03.03.26.
//

import Foundation

/// RPC params for `get_discover_profiles`
struct DiscoverProfilesParams: Encodable {
    let p_limit: Int
    let p_cursor_updated_at: Date?
    let p_cursor_user_id: String?
    let p_relaxed: Bool?

    init(limit: Int, cursorUpdatedAt: Date?, cursorUserId: UUID?, relaxed: Bool? = nil) {
        self.p_limit = limit
        self.p_cursor_updated_at = cursorUpdatedAt
        self.p_cursor_user_id = cursorUserId?.uuidString
        self.p_relaxed = relaxed
    }
}
