import Foundation

/// Mic actions a fast command can request. Executed by the UI layer
/// (which owns VoiceManager) — the router itself touches no hardware.
public enum FastCommandMicAction: Equatable, Sendable {
    case enableMic
    case disableMic
}

/// Result of fast-path routing: either a locally-handled outcome or
/// `.none`, meaning "send to the AI backend normally".
public enum FastCommandAction: Equatable, Sendable {
    /// Answer computed on-device (clock facts). Never presented as AI output.
    case answer(String)
    case cancelCurrent
    case mic(FastCommandMicAction)
    case none
}

/// Low-latency local command path. Safe, read-only device facts and session
/// controls bypass AI processing entirely:
///
/// time, date, stop/cancel, mic on/off.
///
/// Matching is deliberately EXACT (normalized whole input) so normal
/// conversation ("what time does the store open?") always reaches the AI.
/// No unsafe device actions exist here.
public struct FastCommandRouter: Sendable {

    public init() {}

    public func route(_ text: String) -> FastCommandAction {
        let norm = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[?!.,]+$", with: "", options: .regularExpression)

        switch norm {
        case "stop", "cancel", "stop listening", "cancel request", "abort":
            return .cancelCurrent
        case "mic on", "microphone on", "unmute", "start listening", "enable mic":
            return .mic(.enableMic)
        case "mic off", "microphone off", "mute", "stop mic", "disable mic":
            return .mic(.disableMic)
        case "time", "what time is it", "current time", "tell me the time", "what's the time":
            return .answer("The current time is \(Self.timeString()).")
        case "date", "what date is it", "current date", "today's date", "what is today's date", "what day is it":
            return .answer("Today is \(Self.dateString()).")
        default:
            return .none
        }
    }

    // MARK: - Formatters (real device clock)

    private static func timeString(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    private static func dateString(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.timeStyle = .none
        f.dateStyle = .full
        return f.string(from: date)
    }
}
