import Foundation

/// Reconnect policy for the WebSocket layer: bounded exponential backoff.
///
/// - `delay(forAttempt:)` is deterministic when `jitter` is false (unit tests).
/// - Production uses jitter (±25%) to avoid thundering-herd reconnects.
/// - Attempts are capped by `maxAttempts`; afterwards the socket reports
///   `.failed` instead of looping forever.
public struct ReconnectPolicy: Equatable, Sendable {

    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: Bool

    public static let `default` = ReconnectPolicy(
        maxAttempts: 8,
        baseDelay: 1.0,
        maxDelay: 30.0,
        jitter: true
    )

    /// Deterministic variant for tests.
    public static let deterministic = ReconnectPolicy(
        maxAttempts: 8,
        baseDelay: 1.0,
        maxDelay: 30.0,
        jitter: false
    )

    public init(maxAttempts: Int = 8, baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 30.0, jitter: Bool = true) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// Backoff for a 1-based attempt number: base * 2^(attempt-1), capped.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let grown = baseDelay * pow(2.0, Double(attempt - 1))
        let capped = min(grown, maxDelay)
        guard jitter else { return capped }
        let factor = 1.0 + Double.random(in: -0.25...0.25)
        return min(capped * factor, maxDelay)
    }

    public var allowsRetry: Bool { maxAttempts > 0 }
}
