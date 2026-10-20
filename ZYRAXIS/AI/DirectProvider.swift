import Foundation

/// Shared building blocks for direct AI-provider services (Gemini, Groq).
///
/// Design rules for every direct service:
/// - Keys come from Keychain at call time — never stored, never logged.
/// - HTTP statuses map to `NetworkError` (401 → unauthorized, 429 → rate
///   limit, 5xx → server). Timeouts and cancellations propagate.
/// - SSE `data:` line parsing is shared so both streamers behave identically.
/// - History turns are merged so consecutive messages never share a role
///   (Gemini rejects non-alternating contents; harmless for Groq).
public enum DirectProvider {

    /// Free-tier default models. IDs rotate — verify live IDs in
    /// AI Studio (Gemini) / console.groq.com (Groq) and override via each
    /// service's `model` property. Never put keys here.
    ///
    /// Measured against the user's own keys (2026-10-20, single short prompt):
    ///   gemini-flash-lite-latest   ~1.0 s   <- chosen
    ///   gemini-3.5-flash-lite      ~2.5 s
    ///   gemini-3.8-flash          ~74.0 s   (why replies felt like 10 minutes)
    /// `-latest` also tracks Google's current release, so a vendor retirement
    /// can no longer 404 the whole provider.
    public static let defaultGeminiModel = "gemini-flash-lite-latest"
    /// `llama-3.1-8b-instant` was retired by Groq (404 model_not_found), which
    /// broke the fallback chain: Gemini slow → Groq dead → no answer at all.
    public static let defaultGroqModel = "openai/gpt-oss-120b"

    public static let geminiBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
    public static let groqChatURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    // MARK: - Prompt building

    /// System text: app scaffold + request context + memories. No secrets —
    /// callers must never interpolate key material here.
    public static func systemText(context: ConversationContext) -> String {
        var parts: [String] = [AppConfig.systemPrompt]
        if let extra = context.systemPrompt, !extra.isEmpty {
            parts.append(extra)
        }
        let mems = context.memories.prefix(8).compactMap { m -> String? in
            let c = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? nil : "- \(c.prefix(500))"
        }
        if !mems.isEmpty {
            parts.append("User memories:\n" + mems.joined(separator: "\n"))
        }
        if !context.availableTools.isEmpty {
            parts.append("Available tools: " + context.availableTools.prefix(16).joined(separator: ", "))
        }
        if let state = context.assistantState {
            parts.append("Assistant state: \(state)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Merged (role, text) turns, oldest-first, ending with the current text.
    /// Roles collapse to user/assistant; consecutive duplicates merge.
    public static func mergedTurns(context: ConversationContext, currentText: String) -> [(role: String, text: String)] {
        var turns: [(role: String, text: String)] = []
        for m in context.messages {
            let role = (m.role == .assistant) ? "assistant" : "user"
            let text = m.text
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1] = (role, last.text + "\n\n" + text)
            } else {
                turns.append((role, text))
            }
        }
        if let last = turns.last, last.role == "user" {
            turns[turns.count - 1] = ("user", last.text + "\n\n" + currentText)
        } else {
            turns.append(("user", currentText))
        }
        return turns
    }

    // MARK: - HTTP

    /// URLSession honoring the caller's timeout for request + idle reads
    /// (idle-read timeout is what keeps streams bounded).
    ///
    /// `waitsForConnectivity` is FALSE on purpose: with it on, a request that
    /// cannot reach the network sits in "waiting" instead of failing, so the
    /// provider chain above never gets a chance to fall back and the user
    /// stares at a spinner.
    public static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout * 2, 60)
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Maps an HTTP status to NetworkError. 429 keeps its code so the mapper
    /// can report rate limiting precisely.
    public static func statusError(statusCode: Int, message: String?) -> NetworkError {
        switch statusCode {
        case 401:
            return .unauthorized
        case 429:
            return .server(statusCode: 429, message: message)
        case 404:
            return .server(statusCode: 404, message: message)
        case 500..<600:
            return .server(statusCode: statusCode, message: message)
        default:
            return .server(statusCode: statusCode, message: message)
        }
    }

    /// Mirrors URLSessionAPIClient's transport mapping (cancellation stays
    /// CancellationError so the engine takes its clean cancel path).
    public static func transportError(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return NetworkError.timeout
            case .cancelled:
                return CancellationError()
            case .notConnectedToInternet, .networkConnectionLost:
                return NetworkError.noConnection
            default:
                return NetworkError.transport(urlError.localizedDescription)
            }
        }
        if error is NetworkError {
            return error
        }
        return NetworkError.transport(error.localizedDescription)
    }

    // MARK: - SSE

    /// Returns the `data:` payload of one SSE line, or nil when the line
    /// carries nothing (blank, comments, event fields, `[DONE]`).
    public static func ssePayload(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        return String(payload)
    }
}
