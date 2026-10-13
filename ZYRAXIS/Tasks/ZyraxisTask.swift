import Foundation

/// Reminder / task model. Named `ZyraxisTask` to avoid colliding with
/// Swift Concurrency's `Task`.
public struct ZyraxisTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var isCompleted: Bool
    public var isCancelled: Bool
    public var snoozedUntil: Date?
    public var priority: Priority
    public var createdAt: Date
    public var notificationID: String?

    public enum Priority: String, Codable, CaseIterable, Sendable {
        case low, medium, high
    }

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        isCancelled: Bool = false,
        snoozedUntil: Date? = nil,
        priority: Priority = .medium,
        createdAt: Date = Date(),
        notificationID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.isCancelled = isCancelled
        self.snoozedUntil = snoozedUntil
        self.priority = priority
        self.createdAt = createdAt
        self.notificationID = notificationID
    }

    public var isActive: Bool { !isCompleted && !isCancelled }

    /// Effective fire date considering snooze.
    public var effectiveDueDate: Date? {
        if let snoozedUntil { return max(dueDate ?? snoozedUntil, snoozedUntil) }
        return dueDate
    }
}
