import Foundation

/// Structured development logging for ZYRAXIS.
///
/// Categories: AI, NETWORK, WEBSOCKET, VOICE, STATE, TOOL, MEMORY, TASKS, SECURITY.
///
/// Security guarantees:
/// - verbose logs compile to prints in DEBUG only
/// - release builds emit errors only
/// - every message passes through `redacted(_:)` which strips bearer tokens,
///   API keys, passwords and authorization headers
public enum LogCategory: String, Sendable {
    case ai = "AI"
    case network = "NETWORK"
    case websocket = "WEBSOCKET"
    case voice = "VOICE"
    case state = "STATE"
    case tool = "TOOL"
    case memory = "MEMORY"
    case tasks = "TASKS"
    case security = "SECURITY"
}

public enum ZyraxisLogger {

    /// Verbose diagnostic log. DEBUG only — compiled out in release.
    public static func log(_ category: LogCategory, _ message: String) {
        #if DEBUG
        print("[ZYRAXIS][\(category.rawValue)] \(redacted(message))")
        #endif
    }

    /// Error log. Emitted in release too (already redacted).
    public static func error(_ category: LogCategory, _ message: String) {
        print("[ZYRAXIS][\(category.rawValue)][ERROR] \(redacted(message))")
    }

    /// Strips secrets from any log-bound string. Safe to call on already-clean text.
    public static func redacted(_ text: String) -> String {
        var out = text
        // Bearer tokens / authorization headers (full value never logged).
        out = out.replacingOccurrences(
            of: "Bearer\\s+\\S+",
            with: "Bearer [REDACTED]",
            options: [.regularExpression, .caseInsensitive]
        )
        out = out.replacingOccurrences(
            of: "Authorization\\s*:\\s*\\S+",
            with: "Authorization: [REDACTED]",
            options: [.regularExpression, .caseInsensitive]
        )
        // Generic key=value secret patterns.
        let patterns = [
            "(api[_-]?key)\\s*[:=]\\s*\\S+",
            "(token)\\s*[:=]\\s*\\S+",
            "(password)\\s*[:=]\\s*\\S+",
            "(secret)\\s*[:=]\\s*\\S+",
            "(credentials)\\s*[:=]\\s*\\S+"
        ]
        for p in patterns {
            out = out.replacingOccurrences(
                of: p,
                with: "$1=[REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }
}
