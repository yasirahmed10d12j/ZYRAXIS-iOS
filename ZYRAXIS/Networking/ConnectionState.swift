import Foundation

/// Transport-level connection state surfaced to the UI badge.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case suspended
    case failed(String)

    public var displayLabel: String {
        switch self {
        case .disconnected: return "OFFLINE"
        case .connecting: return "CONNECTING"
        case .connected: return "ONLINE"
        case .reconnecting(let a): return "RECONNECTING (\(a))"
        case .suspended: return "SUSPENDED"
        case .failed(let m): return "FAILED — \(m)"
        }
    }

    public var isLive: Bool {
        if case .connected = self { return true }
        return false
    }
}
