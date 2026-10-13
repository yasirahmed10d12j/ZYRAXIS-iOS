import Foundation

/// Structured, user-presentable errors across all ZYRAXIS layers.
public enum AppError: LocalizedError, Equatable, Sendable {
    case network(String)
    case ai(String)
    case voice(String)
    case vision(String)
    case task(String)
    case memory(String)
    case security(String)
    case configuration(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "Network: \(m)"
        case .ai(let m): return "AI: \(m)"
        case .voice(let m): return "Voice: \(m)"
        case .vision(let m): return "Vision: \(m)"
        case .task(let m): return "Task: \(m)"
        case .memory(let m): return "Memory: \(m)"
        case .security(let m): return "Security: \(m)"
        case .configuration(let m): return "Configuration: \(m)"
        case .unknown(let m): return m
        }
    }
}
