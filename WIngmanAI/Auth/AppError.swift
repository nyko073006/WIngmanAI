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
}

