import Foundation

/// ZYRAXIS assistant runtime state.
///
/// The UI observes this via `AssistantStateMachine`.
/// Keep transitions constrained — see `AssistantStateMachine.canTransition(from:to:)`.
public enum AssistantState: String, CaseIterable, Identifiable, Codable, Sendable {
    case idle = "IDLE"
    case listening = "LISTENING"
    case userSpeaking = "USER_SPEAKING"
    case processing = "PROCESSING"
    case speaking = "SPEAKING"
    case executing = "EXECUTING"
    case vision = "VISION"
    case error = "ERROR"

    public var id: String { rawValue }

    /// Human-readable label for the main UI status line.
    public var displayLabel: String {
        switch self {
        case .idle: return "IDLE — Standing by"
        case .listening: return "LISTENING — Mic open"
        case .userSpeaking: return "USER SPEAKING"
        case .processing: return "PROCESSING — Reasoning"
        case .speaking: return "SPEAKING — Responding"
        case .executing: return "EXECUTING — Running task"
        case .vision: return "VISION — Camera analysis"
        case .error: return "ERROR — Attention needed"
        }
    }

    /// Whether the central core should animate as "active".
    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }
}
