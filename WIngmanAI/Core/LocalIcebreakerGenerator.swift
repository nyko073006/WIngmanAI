//
//  LocalIcebreakerGenerator.swift
//  WingmanAI
//
//  Created by Nyko on 09.02.26.
//

import Foundation

enum LocalIcebreakerGenerator {
    static func make(name: String?, city: String?, bio: String, interests: [String]) -> String {
        let displayName = (name?.isEmpty == false) ? name ?? "dir" : "dir"
        let cleanInterests = interests.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if let first = cleanInterests.first {
            return "Hey \(displayName) 😊 Du hast \(first) in deinen Interessen – wie bist du da reingerutscht?"
        }

        if let city, !city.isEmpty {
            return "Hey \(displayName) 😊 Was ist dein Lieblingsspot in \(city)?"
        }

        if !bio.isEmpty {
            return "Hey \(displayName) 😊 Du gibst ja leider nicht soviel von dir Preis, was steckt dahinter?"
        }

        return "Hey \(displayName) 😊 Wenn du heute Abend alles machen könntest: was wäre der perfekte Plan?"
    }
}
