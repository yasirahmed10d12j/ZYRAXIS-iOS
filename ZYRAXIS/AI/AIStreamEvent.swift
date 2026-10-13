import Foundation

/// Stream event kinds. Every event carries its `requestId` so the
/// conversation engine can drop stale/duplicate chunks from superseded
/// requests (cancellation, rapid re-sends).
public enum AIStreamEventType: String, CaseIterable, Sendable {
    case connected
    case thinking
    case textDelta
    case toolCall
    case toolResult
    case speaking
    case completed
    case cancelled
    case error
}

/// Streaming AI events: connection → thinking → text deltas → (tool calls) →
/// speaking → completed, with cancelled/error terminals.
///
/// Honesty rule: only a backend that actually streams may emit `textDelta`.
/// `MockAIService` replays canned chunks and is always `[MOCK]`-labeled.
public enum AIStreamEvent: Equatable, Sendable {
    case connected(requestId: UUID)
    case thinking(requestId: UUID)
    case textDelta(requestId: UUID, delta: String, seq: Int)
    case toolCall(request: ToolCallRequest)
    case toolResult(result: ToolCallResult)
    case speaking(requestId: UUID)
    case completed(requestId: UUID, response: AIResponse)
    case cancelled(requestId: UUID)
    case failed(requestId: UUID, error: AppError)

    public var type: AIStreamEventType {
        switch self {
        case .connected: return .connected
        case .thinking: return .thinking
        case .textDelta: return .textDelta
        case .toolCall: return .toolCall
        case .toolResult: return .toolResult
        case .speaking: return .speaking
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed: return .error
        }
    }

    /// The request this event belongs to (stale-guard key).
    public var requestId: UUID {
        switch self {
        case .connected(let id): return id
        case .thinking(let id): return id
        case .textDelta(let id, _, _): return id
        case .toolCall(let req): return req.requestId
        case .toolResult(let res): return res.requestId
        case .speaking(let id): return id
        case .completed(let id, _): return id
        case .cancelled(let id): return id
        case .failed(let id, _): return id
        }
    }
}
