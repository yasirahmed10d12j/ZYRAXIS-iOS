import Foundation

/// Maps internal failures to user-friendly messages.
///
/// - `userMessage(for:)`: safe for the transcript. Never contains stack
///   traces, URLs with credentials, or token material.
/// - `appError(for:)`: structured error for the state machine.
/// - `diagnostic(for:)`: technical detail for DEBUG logs only.
public enum AssistantErrorMapper {

    public static func userMessage(for error: Error) -> String {
        if error is CancellationError {
            return "Request cancelled."
        }
        if let net = error as? NetworkError {
            switch net {
            case .noConnection:
                return "No network connection. Check your connection and try again."
            case .timeout:
                return "The backend took too long to respond. Try again."
            case .cancelled:
                return "Request cancelled."
            case .unauthorized:
                return "The backend rejected our credentials. Check the API key in Settings."
            case .forbidden:
                return "The backend refused the request (forbidden)."
            case .notFound:
                return "The backend endpoint was not found. Check the backend URL and version."
            case .server(let code, _):
                return "The backend returned an error (\(code)). Try again in a moment."
            case .decoding:
                return "The backend sent a response this app doesn't understand. It may need an update."
            case .transport(let m) where m.lowercased().contains("not configured"):
                return "Backend not configured. Set the backend URL in Settings first."
            case .transport:
                return "Couldn't reach the backend. Check the URL and your connection."
            case .webSocket(let m) where m.lowercased().contains("not connected"):
                return "Not connected to the backend. Check the WebSocket URL in Settings."
            case .webSocket:
                return "The live connection dropped. Reconnecting…"
            case .invalidURL(let u):
                return "The configured backend address looks invalid (\(u))."
            }
        }
        if let proto = error as? BackendProtocolError {
            switch proto {
            case .versionMismatch(let e, let r):
                return "Backend protocol mismatch (app v\(e), server v\(r)). Update the app or backend."
            case .malformedMessage:
                return "Received an unexpected message from the backend. Ignored."
            case .unknownType:
                return "Received an unknown message type. Ignored."
            }
        }
        if let app = error as? AppError {
            return app.localizedDescription
        }
        return "Something went wrong. Try again."
    }

    public static func appError(for error: Error) -> AppError {
        if error is CancellationError || (error as? NetworkError) == .cancelled {
            return .ai("Request cancelled.")
        }
        if let net = error as? NetworkError {
            return .network(net.localizedDescription)
        }
        if error is BackendProtocolError {
            return .network(error.localizedDescription)
        }
        if let app = error as? AppError {
            return app
        }
        return .ai(error.localizedDescription)
    }

    /// Technical detail for DEBUG logs. NEVER show to users.
    public static func diagnostic(for error: Error) -> String {
        return String(reflecting: error)
    }
}
