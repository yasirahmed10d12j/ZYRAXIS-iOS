import Foundation

/// Persistent memory entry. Backend sync arrives in a later phase;
/// the model is already Codable so it can travel over the API unchanged.
public struct MemoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    /// 0...1 recall priority.
    public var importance: Double

    public init(
        id: UUID = UUID(),
        content: String,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        importance: Double = 0.5
    ) {
        self.id = id
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.importance = min(1.0, max(0.0, importance))
    }
}
