import Foundation

/// Local, in-memory memory store for Phase 1 UI development.
///
/// Actor-isolated for Swift Concurrency safety. Deterministic and fully
/// unit-tested; swap for a backend implementation later.
public actor InMemoryMemoryService: MemoryService {

    private var store: [UUID: MemoryItem] = [:]

    public init(seed: [MemoryItem] = []) {
        for item in seed { store[item.id] = item }
    }

    public func save(content: String, tags: [String] = [], importance: Double = 0.5) async throws -> MemoryItem {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryError.emptyContent }
        let item = MemoryItem(content: trimmed, tags: tags, importance: importance)
        store[item.id] = item
        return item
    }

    public func search(query: String, limit: Int = 20) async throws -> [MemoryItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let all = store.values.sorted { $0.updatedAt > $1.updatedAt }
        guard !q.isEmpty else { return Array(all.prefix(limit)) }
        let scored = all.filter {
            $0.content.lowercased().contains(q) ||
            $0.tags.contains(where: { $0.lowercased().contains(q) })
        }
        // Highest importance first, then recency.
        return Array(scored.sorted {
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.updatedAt > $1.updatedAt
        }.prefix(limit))
    }

    public func update(id: UUID, content: String?, tags: [String]?, importance: Double?) async throws -> MemoryItem {
        guard var item = store[id] else { throw MemoryError.notFound }
        if let content {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MemoryError.emptyContent }
            item.content = trimmed
        }
        if let tags { item.tags = tags }
        if let importance { item.importance = min(1.0, max(0.0, importance)) }
        item.updatedAt = Date()
        store[id] = item
        return item
    }

    public func forget(id: UUID) async throws {
        guard store.removeValue(forKey: id) != nil else { throw MemoryError.notFound }
    }

    public func listAll() async throws -> [MemoryItem] {
        return store.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}
