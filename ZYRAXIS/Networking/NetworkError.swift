import Foundation

/// Structured networking failures. Never surface raw URLSession errors to UI.
public enum NetworkError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case noConnection
    case timeout
    case cancelled
    case unauthorized
    case forbidden
    case notFound
    case server(statusCode: Int, message: String?)
    case decoding(String)
    case transport(String)
    case webSocket(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "Invalid URL: \(u)"
        case .noConnection: return "No network connection."
        case .timeout: return "Request timed out."
        case .cancelled: return "Request was cancelled."
        case .unauthorized: return "Unauthorized (401). Check backend credentials."
        case .forbidden: return "Forbidden (403)."
        case .notFound: return "Endpoint not found (404)."
        case .server(let code, let msg):
            return "Server error (\(code)): \(msg ?? "no detail")"
        case .decoding(let m): return "Decoding failed: \(m)"
        case .transport(let m): return "Transport error: \(m)"
        case .webSocket(let m): return "WebSocket error: \(m)"
        }
    }

    /// Map HTTP status codes to typed errors.
    public static func fromStatusCode(_ code: Int, message: String? = nil) -> NetworkError {
        switch code {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 200..<300: return .server(statusCode: code, message: "fromStatusCode called with success code")
        default: return .server(statusCode: code, message: message)
        }
    }
}
