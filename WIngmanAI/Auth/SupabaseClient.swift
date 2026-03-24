//
//  SupabaseClient.swift
//  WingmanAI
//
//  Single source of truth for the Supabase client lives in SupabaseClientProvider.
//  This file intentionally does NOT declare any singleton types to avoid redeclaration
//  collisions across the project.
//

import Foundation
import Supabase

// Keep this file as a lightweight import point if other files reference it.
// Do not add singletons or services here.
