import Foundation
@preconcurrency import UserNotifications

/// Reminder-notification abstraction over UserNotifications.
public protocol NotificationService: Sendable {
    func requestAuthorization() async throws -> Bool
    func scheduleTaskReminder(title: String, body: String?, at date: Date) async throws -> String
    func cancelReminder(id: String) async
    func pendingCount() async throws -> Int
}

public struct UNNotificationService: NotificationService, Sendable {

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    public func scheduleTaskReminder(title: String, body: String?, at date: Date) async throws -> String {
        let id = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "ZYRAXIS Reminder"
        content.body = title + (body.map { " — \($0)" } ?? "")
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try await center.add(request)
        return id
    }

    public func cancelReminder(id: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    public func pendingCount() async throws -> Int {
        await withCheckedContinuation { cont in
            center.getPendingNotificationRequests { reqs in
                cont.resume(returning: reqs.count)
            }
        }
    }
}
