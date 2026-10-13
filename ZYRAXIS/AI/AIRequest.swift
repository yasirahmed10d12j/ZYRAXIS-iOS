import Foundation

/// Bounded context limits. The client NEVER sends unlimited history —
/// ContextManager enforces these caps on every request.
public struct ContextLimits: Codable, Equatable, Sendable {
    public var maxMessages: Int
    public var maxMemories: Int
    public var maxTotalChars: Int
    public var maxMemoryChars: Int

    public static let `default` = ContextLimits(
        maxMessages: 20,
        maxMemories: 5,
        maxTotalChars: 8000,
        maxMemoryChars: 2000
    )

    public init(maxMessages: Int = 20, maxMemories: Int = 5, maxTotalChars: Int = 8000, maxMemoryChars: Int = 2000) {
        self.maxMessages = maxMessages
        self.maxMemories = maxMemories
        self.maxTotalChars = maxTotalChars
        self.maxMemoryChars = maxMemoryChars
    }
}

/// Minimal, non-sensitive device context. Never includes identifiers,
/// location, contacts, or anything private.
public struct DeviceContext: Codable, Equatable, Sendable {
    public var deviceModel: String?
    public var osVersion: String?
    public var appVersion: String?
    public var locale: String?

    public init(deviceModel: String? = nil, osVersion: String? = nil, appVersion: String? = nil, locale: String? = nil) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.locale = locale
    }
}

/// Bounded, wire-friendly conversation snapshot produced by ContextManager.
///
/// system context + recent conversation + relevant memory + assistant state
/// + available tools + device context — all capped by `ContextLimits`.
public struct ConversationContext: Codable, Equatable, Sendable {
    public var systemPrompt: String?
    /// Chronological, oldest-first, already truncated to limits.
    public var messages: [ConversationMessage]
    public var memories: [MemoryItem]
    /// AssistantState rawValue at request time (informational for the backend).
    public var assistantState: String?
    public var availableTools: [String]
    public var device: DeviceContext?

    public init(
        systemPrompt: String? = nil,
        messages: [ConversationMessage] = [],
        memories: [MemoryItem] = [],
        assistantState: String? = nil,
        availableTools: [String] = [],
        device: DeviceContext? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.memories = memories
        self.assistantState = assistantState
        self.availableTools = availableTools
        self.device = device
    }
}

/// A single AI turn: text + bounded context + identity + timeout.
public struct AIRequest: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var context: ConversationContext
    public var timeout: TimeInterval

    public init(id: UUID = UUID(), text: String, context: ConversationContext, timeout: TimeInterval = 60) {
        self.id = id
        self.text = text
        self.context = context
        self.timeout = timeout
    }
}

/// A model-requested tool invocation within a request.
public struct ToolCallRequest: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { toolCall.id }
    public var toolCall: ToolCall
    public var requestId: UUID

    public init(toolCall: ToolCall, requestId: UUID) {
        self.toolCall = toolCall
        self.requestId = requestId
    }
}

/// Outcome of a tool invocation (executed server-side in Phase 2).
public struct ToolCallResult: Equatable, Sendable {
    public var requestId: UUID
    public var toolName: String
    public var outputJSON: String
    public var error: String?

    public var succeeded: Bool { error == nil }

    public init(requestId: UUID, toolName: String, outputJSON: String = "{}", error: String? = nil) {
        self.requestId = requestId
        self.toolName = toolName
        self.outputJSON = outputJSON
        self.error = error
    }
}
