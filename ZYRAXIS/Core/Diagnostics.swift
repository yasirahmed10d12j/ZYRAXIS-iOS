import Foundation

/// Monotonic per-request timing (Phase 3):
///
/// T0 = user message dispatched · T1 = request accepted (first event) ·
/// T2 = first assistant delta · T3 = last assistant delta · T4 = terminal.
///
/// Derived: time-to-first-token (T2−T0), stream duration (T3−T2),
/// total response time (T4−T0). Uses `ContinuousClock` (monotonic —
/// immune to wall-clock changes). No artificial delays are added anywhere.
public struct RequestTiming: Equatable, Sendable {
    public var requestId: UUID
    public var t0Sent: ContinuousClock.Instant
    public var t1Accepted: ContinuousClock.Instant?
    public var t2FirstDelta: ContinuousClock.Instant?
    public var t3LastDelta: ContinuousClock.Instant?
    public var t4Done: ContinuousClock.Instant?

    public init(requestId: UUID, clock: ContinuousClock = ContinuousClock()) {
        self.requestId = requestId
        self.t0Sent = clock.now
    }

    /// Time to first token, when the first delta arrived.
    public var timeToFirstToken: Duration? {
        guard let t2 = t2FirstDelta else { return nil }
        return t0Sent.duration(to: t2)
    }

    /// Stream duration between first and last delta.
    public var streamDuration: Duration? {
        guard let t2 = t2FirstDelta, let t3 = t3LastDelta else { return nil }
        return t2.duration(to: t3)
    }

    /// Total response time from dispatch to terminal.
    public var totalResponseTime: Duration? {
        guard let t4 = t4Done else { return nil }
        return t0Sent.duration(to: t4)
    }
}

public extension Duration {
    /// Whole milliseconds for diagnostics display.
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }

    var displayString: String {
        let ms = milliseconds
        if ms < 1_000 { return "\(ms) ms" }
        return String(format: "%.2f s", Double(ms) / 1_000.0)
    }
}

/// Diagnostics helpers. Never include credentials — URLs are reduced to
/// scheme + host before display.
public enum DiagnosticsSupport {
    /// `https://user:pass@host:8080/path?q=1` → `https://host:8080`.
    /// Nil/empty input → "—".
    public static func sanitizedHostString(for url: URL?) -> String {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return "—" }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    public static func dateString(for date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }
}
