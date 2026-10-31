import Foundation

enum SupportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return localizedMessage(text) }; return nil }
}
