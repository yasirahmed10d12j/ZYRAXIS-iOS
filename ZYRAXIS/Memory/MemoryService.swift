import Foundation

/// Modular memory abstraction. Phase 1 ships an in-memory implementation;
/// a backend-backed one can replace it without touching UI or AI layers.
public protocol MemoryService: Sendable {
    func save(content: String, tags: [String], importance: Double) async throws -> MemoryItem
    func search(query: String, limit: Int) async throws -> [MemoryItem]
    func update(id: UUID, content: String?, tags: [String]?, importance: Double?) async throws -> MemoryItem
    func forget(id: UUID) async throws
    func listAll() async throws -> [MemoryItem]
}

public enum MemoryError: LocalizedError, Equatable {
    case notFound
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Memory not found."
        case .emptyContent: return "Memory content must not be empty."
        }
    }
}
