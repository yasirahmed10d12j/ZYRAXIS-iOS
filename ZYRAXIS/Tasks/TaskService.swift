import Foundation

public enum TaskFilter: Sendable {
    case all
    case active
    case completed
    case cancelled
    case dueToday
}

public enum TaskError: LocalizedError, Equatable, Sendable {
    case notFound
    case emptyTitle
    case invalidSnoozeDate

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Task not found."
        case .emptyTitle: return "Task title must not be empty."
        case .invalidSnoozeDate: return "Snooze date must be in the future."
        }
    }
}

/// Task/reminder abstraction. Phase 1 ships a local implementation with
/// UserNotifications scheduling; backend sync arrives later.
public protocol TaskService: Sendable {
    func create(title: String, notes: String?, dueDate: Date?, priority: ZyraxisTask.Priority) async throws -> ZyraxisTask
    func list(filter: TaskFilter) async throws -> [ZyraxisTask]
    func update(id: UUID, title: String?, notes: String?, dueDate: Date?, priority: ZyraxisTask.Priority?) async throws -> ZyraxisTask
    func cancel(id: UUID) async throws -> ZyraxisTask
    func complete(id: UUID) async throws -> ZyraxisTask
    func snooze(id: UUID, until: Date) async throws -> ZyraxisTask
}
