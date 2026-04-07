//
//  PhotoService.swift
//  WingmanAI
//
//  Created by Nyko on 10.02.26.
//

import Foundation
import Supabase

final class PhotoService {
    static let shared = PhotoService()
    private init() {}

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }
    let bucket = "profile-photos"

    struct PhotoRow: Decodable {
        let id: UUID
        let user_id: UUID
        let url: String
        let sort_order: Int
        let created_at: Date
    }

    /// Uploads image bytes to Storage and inserts DB row into `photos`.
    /// Returns the public URL.
    func uploadProfilePhoto(
        userId: UUID,
        jpegData: Data,
        sortOrder: Int = 0,
        isSnapshot: Bool = false
    ) async throws -> String {

        let photoId = UUID()
        let path = "\(userId.uuidString)/\(photoId.uuidString).jpg"

        // 1) upload to storage
        _ = try await client.storage
            .from(bucket)
            .upload(
                path,
                data: jpegData,
                options: FileOptions(
                    contentType: "image/jpeg",
                    upsert: true
                )
            )

        // 2) get public URL (bucket must be public for this)
        let publicUrl = try client.storage.from(bucket).getPublicURL(path: path)
        let publicUrlString = publicUrl.absoluteString

        // 3) insert DB row
        struct Insert: Encodable {
            let user_id: String
            let url: String
            let sort_order: Int
            let is_snapshot: Bool
        }

        _ = try await client
            .from("photos")
            .insert(Insert(user_id: userId.uuidString, url: publicUrlString, sort_order: sortOrder, is_snapshot: isSnapshot))
            .execute()

        return publicUrlString
    }

    /// Returns first photo url for each user id (MVP: 1 query).
    func fetchPrimaryPhotos(userIds: [UUID]) async throws -> [UUID: String] {
        guard !userIds.isEmpty else { return [:] }

        struct Row: Decodable {
            let user_id: UUID
            let url: String
            let sort_order: Int
            let created_at: Date
        }

        let rows: [Row] = try await client
            .from("photos")
            .select("user_id,url,sort_order,created_at")
            .in("user_id", values: userIds.map { $0.uuidString })
            .eq("is_snapshot", value: false)
            .order("sort_order", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value

        // pick first per user
        var out: [UUID: String] = [:]
        for r in rows {
            if out[r.user_id] == nil { out[r.user_id] = r.url }
        }
        return out
    }
}
