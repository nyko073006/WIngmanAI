import Foundation

struct AppError: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String

    init(id: UUID = UUID(), title: String, message: String) {
        self.id = id
        self.title = title
        self.message = message
    }

    static func simple(_ title: String, _ message: String) -> AppError {
        AppError(title: title, message: message)
    }

    // MARK: - User-friendly error mapping

    /// Maps any Swift / Foundation / Supabase error to a human-readable German string.
    static func userMessage(for error: Error) -> String {
        // Always log the raw error so it appears in TestFlight / Xcode Organizer logs
        print("[AppError] \(type(of: error)): \(error)")

        // 1. Network / URLSession errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Keine Internetverbindung. Prüfe deine Verbindung und versuche es erneut."
            case .timedOut:
                return "Zeitüberschreitung. Bitte versuche es erneut."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Server nicht erreichbar. Versuche es später erneut."
            case .cancelled:
                return "Anfrage abgebrochen."
            default:
                return "Netzwerkfehler (\(urlError.code.rawValue)). Bitte versuche es erneut."
            }
        }

        // 2. JSON decode errors — mismatch between Swift model and DB response
        if let decodeError = error as? DecodingError {
            switch decodeError {
            case .typeMismatch(let type, let ctx):
                print("[AppError] Decode typeMismatch – expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                return "Datenfehler: Serverantwort hat unerwartetes Format. (typeMismatch)"
            case .keyNotFound(let key, _):
                print("[AppError] Decode keyNotFound – missing key '\(key.stringValue)'")
                return "Datenfehler: Pflichtfeld '\(key.stringValue)' fehlt in Serverantwort."
            case .valueNotFound(let type, let ctx):
                print("[AppError] Decode valueNotFound – \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                return "Datenfehler: Pflichtfeld ist null in Serverantwort."
            case .dataCorrupted(let ctx):
                print("[AppError] Decode dataCorrupted – \(ctx.debugDescription)")
                return "Datenfehler: Antwort konnte nicht gelesen werden."
            @unknown default:
                return "Datenfehler: Bitte versuche es erneut."
            }
        }

        // 3. AI Edge Function errors (domain = "AIService")
        let nsError = error as NSError
        if nsError.domain == "AIService" {
            switch nsError.code {
            case 429:
                return "Dein KI-Tageslimit ist erreicht. Upgrade auf Premium für mehr Vorschläge."
            case 401:
                return "Sitzung abgelaufen. Bitte melde dich erneut an."
            case 500, 502, 503, 504:
                return "Der KI-Server ist gerade nicht verfügbar. Versuche es in Kürze erneut."
            default:
                return "KI-Fehler. Bitte versuche es erneut."
            }
        }

        // 4. Supabase / GoTrue auth errors — match on localized description content
        let raw = error.localizedDescription.lowercased()

        if raw.contains("invalid login credentials") || raw.contains("invalid email or password") || raw.contains("wrong password") {
            return "E-Mail oder Passwort ist falsch."
        }
        if raw.contains("user already registered") || raw.contains("already been registered") || raw.contains("email already exists") {
            return "Diese E-Mail ist bereits registriert. Melde dich an oder nutze 'Passwort vergessen'."
        }
        if raw.contains("email not confirmed") || raw.contains("email_not_confirmed") {
            return "Bitte bestätige zuerst deine E-Mail-Adresse. Schau in deinen Posteingang."
        }
        if raw.contains("password should be at least") || raw.contains("password is too short") || raw.contains("weak password") {
            return "Das Passwort muss mindestens 6 Zeichen lang sein."
        }
        if raw.contains("rate limit") || raw.contains("too many requests") {
            return "Zu viele Versuche. Bitte warte kurz und versuche es erneut."
        }
        if raw.contains("jwt expired") || raw.contains("session expired") || raw.contains("not authenticated") || raw.contains("refresh_token_not_found") {
            return "Deine Sitzung ist abgelaufen. Bitte melde dich erneut an."
        }
        if raw.contains("daily ai limit") || raw.contains("daily limit reached") {
            return "Dein KI-Tageslimit ist erreicht. Upgrade auf Premium für mehr."
        }
        if raw.contains("user not found") || raw.contains("no user found") {
            return "Kein Account mit dieser E-Mail-Adresse gefunden."
        }
        if raw.contains("signup_disabled") || raw.contains("sign up is disabled") {
            return "Registrierung ist derzeit deaktiviert."
        }
        if raw.contains("network") || raw.contains("offline") || raw.contains("no internet") {
            return "Keine Verbindung. Bitte prüfe dein Internet."
        }
        // PostgREST: function not found (PGRST202) or permission denied (42501)
        if raw.contains("pgrst202") || raw.contains("could not find the function") {
            return "Serverfehler: Funktion nicht gefunden. Bitte App aktualisieren."
        }
        if raw.contains("42501") || raw.contains("permission denied") || raw.contains("row-level security") {
            return "Zugriff verweigert. Bitte melde dich erneut an."
        }

        // 5. Generic fallback — show raw error during beta for diagnosis
        print("[AppError] Unhandled error falling back to generic message.")
        return "Fehler: \(error.localizedDescription)"
    }
}
