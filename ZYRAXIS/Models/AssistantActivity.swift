import Foundation

/// Lightweight activity feed entry shown under the ZYRAXIS core
/// (listening / thinking / tool runs / errors).
public struct AssistantActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var timestamp: Date

    public enum Kind: String, Sendable {
        case listening
        case thinking
        case speaking
        case tool
        case vision
        case system
        case error
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
    }
}
