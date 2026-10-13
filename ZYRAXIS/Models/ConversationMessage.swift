import Foundation

/// A single turn in the conversation transcript.
public struct ConversationMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var role: Role
    public var text: String
    public var timestamp: Date
    /// True while a streaming response is still arriving.
    public var isStreaming: Bool

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
        case tool
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
}
