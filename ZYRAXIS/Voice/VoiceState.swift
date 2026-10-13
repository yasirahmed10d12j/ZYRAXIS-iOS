import Foundation

/// Microphone / audio-capture state. UI-observable via VoiceManager.
public enum VoiceState: Equatable, Sendable {
    case idle
    case requestingPermission
    case ready
    case listening(level: Float)
    case stopped
    case denied
    case failed(String)

    public var displayLabel: String {
        switch self {
        case .idle: return "MIC IDLE"
        case .requestingPermission: return "REQUESTING MIC"
        case .ready: return "MIC READY"
        case .listening: return "CAPTURING AUDIO"
        case .stopped: return "MIC STOPPED"
        case .denied: return "MIC DENIED"
        case .failed(let m): return "MIC ERROR — \(m)"
        }
    }

    public var isCapturing: Bool {
        if case .listening = self { return true }
        return false
    }
}
