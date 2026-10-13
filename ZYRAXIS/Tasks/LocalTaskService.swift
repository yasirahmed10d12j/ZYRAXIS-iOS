import Foundation

/// Local task store. Persists to UserDefaults (lightweight, no CoreData
/// dependency in Phase 1) and schedules reminders via NotificationService.
///
/// Notification scheduling is best-effort: task CRUD never fails just
/// because notifications were denied.
public actor LocalTaskService: TaskService {

    private var store: [UUID: ZyraxisTask] = [:]
    private let storageKey = "zyraxis.tasks.v1"
    private let notifications: NotificationService?

    public init(notifications: NotificationService? = nil, seed: [ZyraxisTask] = []) {
        self.notifications = notifications
        for t in seed { store[t.id] = t }
        // Load persisted snapshot (synchronously within init via UserDefaults).
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ZyraxisTask].self, from: data) {
            for t in saved { store[t.id] = t }
        }
    }

    public func create(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: ZyraxisTask.Priority = .medium
    ) async throws -> ZyraxisTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskError.emptyTitle }
        var task = ZyraxisTask(title: trimmed, notes: notes, dueDate: dueDate, priority: priority)
        task.notificationID = await scheduleReminder(for: task)
        store[task.id] = task
        persist()
        return task
    }

    public func list(filter: TaskFilter = .all) async throws -> [ZyraxisTask] {
        let all = store.values.sorted { $0.createdAt > $1.createdAt }
        switch filter {
        case .all: return all
        case .active: return all.filter { $0.isActive }
        case .completed: return all.filter { $0.isCompleted }
        case .cancelled: return all.filter { $0.isCancelled }
        case .dueToday:
            return all.filter {
                guard let due = $0.effectiveDueDate else { return false }
                return Calendar.current.isDateInToday(due) && $0.isActive
            }
        }
    }

    public func update(
        id: UUID,
        title: String?,
        notes: String?,
        dueDate: Date?,
        priority: ZyraxisTask.Priority?
    ) async throws -> ZyraxisTask {
        guard var task = store[id] else { throw TaskError.notFound }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw TaskError.emptyTitle }
            task.title = trimmed
        }
        if let notes { task.notes = notes }
        if let dueDate { task.dueDate = dueDate }
        if let priority { task.priority = priority }
        await reschedule(for: &task)
        store[id] = task
        persist()
        return task
    }

    public func cancel(id: UUID) async throws -> ZyraxisTask {
        guard var task = store[id] else { throw TaskError.notFound }
        task.isCancelled = true
        await cancelReminder(for: task)
        task.notificationID = nil
        store[id] = task
        persist()
        return task
    }

    public func complete(id: UUID) async throws -> ZyraxisTask {
        guard var task = store[id] else { throw TaskError.notFound }
        task.isCompleted = true
        await cancelReminder(for: task)
        task.notificationID = nil
        store[id] = task
        persist()
        return task
    }

    public func snooze(id: UUID, until: Date) async throws -> ZyraxisTask {
        guard until > Date() else { throw TaskError.invalidSnoozeDate }
        guard var task = store[id] else { throw TaskError.notFound }
        task.snoozedUntil = until
        await reschedule(for: &task)
        store[id] = task
        persist()
        return task
    }

    // MARK: - Private

    private func scheduleReminder(for task: ZyraxisTask) async -> String? {
        guard let notifications, let due = task.effectiveDueDate, due > Date() else { return nil }
        do {
            return try await notifications.scheduleTaskReminder(title: task.title, body: task.notes, at: due)
        } catch {
            return nil // best-effort
        }
    }

    private func reschedule(for task: inout ZyraxisTask) async {
        await cancelReminder(for: task)
        task.notificationID = await scheduleReminder(for: task)
    }

    private func cancelReminder(for task: ZyraxisTask) async {
        if let nid = task.notificationID {
            await notifications?.cancelReminder(id: nid)
        }
    }

    private func persist() {
        let snapshot = Array(store.values)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
