import Foundation
import Combine

/// Observable assistant state machine.
///
/// Layering: UI observes this object. It sits above the AI / agent / backend
/// layers and never performs networking itself.
///
/// Threading: `@MainActor` so SwiftUI can observe `@Published` state safely.
@MainActor
public final class AssistantStateMachine: ObservableObject {

    @Published public private(set) var state: AssistantState = .idle
    @Published public private(set) var lastError: AppError?
    @Published public private(set) var stateHistory: [AssistantState] = [.idle]

    public init(initialState: AssistantState = .idle) {
        self.state = initialState
        self.stateHistory = [initialState]
    }

    // MARK: - Transition rules

    /// Allowed transitions. Kept intentionally explicit so invalid
    /// voice/AI interleavings are caught in tests and in debug builds.
    /// Pure function of its arguments (no actor state), so `nonisolated`:
    /// callable from any context without weakening the transition rules.
    public nonisolated static func canTransition(from: AssistantState, to: AssistantState) -> Bool {
        if from == to { return true }
        switch from {
        case .idle:
            return [.listening, .processing, .vision, .executing, .error].contains(to)
        case .listening:
            return [.userSpeaking, .processing, .idle, .error].contains(to)
        case .userSpeaking:
            return [.processing, .listening, .idle, .error].contains(to)
        case .processing:
            return [.speaking, .executing, .idle, .error].contains(to)
        case .speaking:
            return [.idle, .listening, .error].contains(to)
        case .executing:
            return [.processing, .speaking, .idle, .error].contains(to)
        case .vision:
            return [.processing, .idle, .error].contains(to)
        case .error:
            // Error is sticky until explicitly reset to idle.
            return to == .idle
        }
    }

    /// Attempt a transition. Returns true on success.
    /// Invalid transitions are ignored (and logged in DEBUG) — they never crash release builds.
    @discardableResult
    public func transition(to newState: AssistantState) -> Bool {
        guard Self.canTransition(from: state, to: newState) else {
            #if DEBUG
            print("[AssistantStateMachine] rejected transition \(state.rawValue) -> \(newState.rawValue)")
            #endif
            return false
        }
        if newState != .error {
            lastError = nil
        }
        state = newState
        stateHistory.append(newState)
        // Bound history to avoid unbounded growth on long sessions.
        if stateHistory.count > 200 {
            stateHistory.removeFirst(stateHistory.count - 200)
        }
        return true
    }

    /// Enter the error state with a structured error.
    public func fail(with error: AppError) {
        lastError = error
        // Force-transition: error can be reached from any state.
        state = .error
        stateHistory.append(.error)
        // Same 200-entry bound as transition(to:) — fail() bypasses it above.
        if stateHistory.count > 200 {
            stateHistory.removeFirst(stateHistory.count - 200)
        }
    }

    /// Recover from error back to idle. Only valid from `.error`.
    @discardableResult
    public func resetToIdle() -> Bool {
        return transition(to: .idle)
    }

    // MARK: - Convenience intents (used by UI / voice layer)

    public func beginListening() -> Bool { transition(to: .listening) }
    public func markUserSpeaking() -> Bool { transition(to: .userSpeaking) }
    public func beginProcessing() -> Bool { transition(to: .processing) }
    public func beginSpeaking() -> Bool { transition(to: .speaking) }
    public func beginExecuting() -> Bool { transition(to: .executing) }
    public func beginVision() -> Bool { transition(to: .vision) }
}
