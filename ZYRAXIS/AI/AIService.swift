import Foundation

/// Which backend answers conversational requests.
public enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Local mock for UI development only. Clearly surfaced in the UI.
    case mock
    /// ZYRAXIS backend over HTTPS / WebSocket (Phase 2: BackendAIService).
    /// Requires a running backend + configured URLs + Keychain API key.
    case customBackend
    /// Future Gemini Live / realtime provider. Not implemented in Phase 2.
    case realtimeFuture

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mock: return "Mock (local UI dev)"
        case .customBackend: return "ZYRAXIS Backend"
        case .realtimeFuture: return "Realtime (future)"
        }
    }

    public var isImplemented: Bool {
        switch self {
        case .mock, .customBackend: return true
        case .realtimeFuture: return false
        }
    }
}

/// Context passed to the AI layer: history + optional memory + system prompt.
///
/// Phase 2 additions (all defaulted, so Phase 1 call sites compile unchanged):
/// the assistant state at request time, available tool names for the backend,
/// non-sensitive device context, and the limits ContextManager enforces.
public struct AIContext: Equatable, Sendable {
    public var history: [ConversationMessage]
    public var memories: [MemoryItem]
    public var systemPrompt: String?
    public var assistantState: AssistantState?
    public var availableTools: [String]
    public var device: DeviceContext?
    public var limits: ContextLimits

    public init(
        history: [ConversationMessage] = [],
        memories: [MemoryItem] = [],
        systemPrompt: String? = nil,
        assistantState: AssistantState? = nil,
        availableTools: [String] = [],
        device: DeviceContext? = nil,
        limits: ContextLimits = .default
    ) {
        self.history = history
        self.memories = memories
        self.systemPrompt = systemPrompt
        self.assistantState = assistantState
        self.availableTools = availableTools
        self.device = device
        self.limits = limits
    }
}

/// A tool invocation requested by the model (routed via ToolRegistry later).
public struct ToolCall: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var toolName: String
    public var argumentsJSON: String

    public init(id: UUID = UUID(), toolName: String, argumentsJSON: String = "{}") {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

/// Final non-streaming answer.
public struct AIResponse: Equatable, Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    /// Set by streaming backends; nil for local/mock answers.
    public var requestId: UUID?

    public init(text: String, toolCalls: [ToolCall] = [], requestId: UUID? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.requestId = requestId
    }
}

/// Conversational AI abstraction.
///
/// UI talks only to this protocol (via ConversationManager), so providers
/// swap without touching views.
///
/// Concurrency note: the protocol is intentionally NOT `Sendable`-constrained.
/// Real services are `@MainActor`-bound (they observe the socket's published
/// state), and all consumption happens on `MainActor` via ConversationManager.
/// Value-type services (mock, test doubles) still conform to `Sendable`.
public protocol AIService {
    var provider: AIProvider { get }
    /// Live transport state for the connection badge. Defaults to
    /// `.disconnected` (honest for connectionless services like the mock).
    var connectionState: ConnectionState { get }
    /// Primary API: the request carries its ID, and every stream event echoes
    /// it — this is what lets the engine drop stale/duplicate chunks.
    func sendMessage(_ request: AIRequest) async throws -> AIResponse
    func streamMessage(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Best-effort cancellation of one in-flight request. Defaults to no-op.
    func cancelRequest(id: UUID) async
    /// Sends a locally-produced tool result back to the server for the given
    /// request. Defaults to no-op (connectionless services, mocks).
    func sendToolResult(_ result: ToolCallResult) async
}

public extension AIService {
    var connectionState: ConnectionState { .disconnected }
    func cancelRequest(id: UUID) async {}
    func sendToolResult(_ result: ToolCallResult) async {}

    /// Convenience for one-shot callers: builds an unbounded `AIRequest`.
    /// The engine always uses bounded contexts via ContextManager instead.
    func sendMessage(_ text: String, context: AIContext) async throws -> AIResponse {
        try await sendMessage(AIRequest(text: text, context: Self.context(from: context)))
    }

    func streamMessage(_ text: String, context: AIContext) -> AsyncThrowingStream<AIStreamEvent, Error> {
        streamMessage(AIRequest(text: text, context: Self.context(from: context)))
    }

    private static func context(from legacy: AIContext) -> ConversationContext {
        ConversationContext(
            systemPrompt: legacy.systemPrompt,
            messages: legacy.history,
            memories: legacy.memories,
            assistantState: legacy.assistantState?.rawValue,
            availableTools: legacy.availableTools,
            device: legacy.device
        )
    }
}
