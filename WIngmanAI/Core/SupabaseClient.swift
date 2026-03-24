//
//  SupabaseClient.swift
//  WIngmanAI
//
//  Created by Nyko on 31.01.26.
//

import Foundation
import Supabase

enum SupabaseConfig {
    static var url: URL {
        guard
            let path = Bundle.main.path(forResource: "Supabase", ofType: "plist"),
            let dict = NSDictionary(contentsOfFile: path),
            let urlString = dict["SUPABASE_URL"] as? String,
            let url = URL(string: urlString)
        else { fatalError("Missing SUPABASE_URL in Supabase.plist") }
        return url
    }

    static var anonKey: String {
        guard
            let path = Bundle.main.path(forResource: "Supabase", ofType: "plist"),
            let dict = NSDictionary(contentsOfFile: path),
            let key = dict["SUPABASE_ANON_KEY"] as? String
        else { fatalError("Missing SUPABASE_ANON_KEY in Supabase.plist") }
        return key
    }
}

final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
    }
}
