import Foundation
import UIKit
import UserNotifications

/// Read-only access to delivered notifications via UNUserNotificationCenter.
/// No private APIs, no background access — only notifications already delivered
/// to the user (the same ones visible in Notification Center).
public struct NotificationTool: AgentTool, Sendable {

    public var name: String { "get_notifications" }
    public var description: String {
        "Returns recently delivered notifications (same as Notification Center). Limited to what iOS allows third-party apps to read."
    }
    public var parametersJSONSchema: String { "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":50,\"default\":10},\"includeContent\":{\"type\":\"boolean\",\"default\":true}}}" }
    public var riskLevel: ToolRiskLevel { .readOnly }
    public var requiresConfirmation: Bool { false }

    public init() {}

    public func execute(input: ToolInput) async throws -> ToolOutput {
        let args = try decodeArguments(input.rawJSON)
        let limit = (args["limit"] as? Int) ?? 10
        let includeContent = (args["includeContent"] as? Bool) ?? true

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            return ToolOutput(text: "Notifications permission not granted. Enable in iOS Settings.")
        }

        let delivered = await center.deliveredNotifications()
        let recent = delivered.suffix(limit).reversed()

        var items: [[String: Any]] = []
        for n in recent {
            let req = n.request
            let content = req.content
            var item: [String: Any] = [
                "identifier": req.identifier,
                "title": content.title,
                "subtitle": content.subtitle,
                "threadIdentifier": req.content.threadIdentifier,
                "date": ISO8601DateFormatter().string(from: n.date)
            ]
            if includeContent {
                item["body"] = content.body
            }
            items.append(item)
        }

        let data = try JSONSerialization.data(withJSONObject: ["notifications": items, "count": items.count], options: .prettyPrinted)
        return ToolOutput(text: String(data: data, encoding: .utf8) ?? "{}")
    }

    private func decodeArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

/// Alarm tool — iOS does NOT let third-party apps set alarms directly.
/// This tool opens the Clock app (via Shortcuts or universal link) so the
/// user can set the alarm themselves. Honest about the limitation.
public struct AlarmTool: AgentTool, Sendable {

    public var name: String { "set_alarm" }
    public var description: String {
        "Opens the Clock app to set an alarm. iOS does not allow third-party apps to set alarms directly — this opens the system Clock app where you can create it."
    }
    public var parametersJSONSchema: String { "{\"type\":\"object\",\"properties\":{\"time\":{\"type\":\"string\",\"description\":\"Alarm time in HH:mm format (24h), e.g. 07:30\"},\"label\":{\"type\":\"string\",\"description\":\"Optional label for the alarm\"}}}" }
    public var riskLevel: ToolRiskLevel { .reversible }
    public var requiresConfirmation: Bool { true }

    public init() {}

    public func execute(input: ToolInput) async throws -> ToolOutput {
        let args = try decodeArguments(input.rawJSON)
        guard let time = args["time"] as? String else {
            return ToolOutput(text: "Missing required 'time' parameter (HH:mm).")
        }
        let label = (args["label"] as? String) ?? "ZYRAXIS alarm"

        // Validate HH:mm format
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), hour >= 0 && hour <= 23,
              let minute = Int(parts[1]), minute >= 0 && minute <= 59 else {
            return ToolOutput(text: "Invalid time format. Use HH:mm (24h), e.g. 07:30.")
        }

        // Open Clock app via Shortcuts URL (most reliable) or generic clock link
        // Clock app doesn't have a public deep link for "create alarm", but Shortcuts can.
        // Fallback: open Shortcuts app with a pre-filled alarm creation shortcut.
        let encodedLabel = label.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? ""
        let encodedTime = time.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? ""
        let shortcutName = "Create Alarm".addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? ""
        let shortcutURL = "shortcuts://run-shortcut?name=\(shortcutName)&input=\(encodedTime)%20\(encodedLabel)"

        let urls = [
            URL(string: shortcutURL),
            URL(string: "clock://"),
            URL(string: "shortcuts://")
        ].compactMap { $0 }

        guard let url = urls.first else {
            return ToolOutput(text: "Could not construct Clock/Shortcuts URL.")
        }

        await MainActor.run {
            UIApplication.shared.open(url)
        }

        return ToolOutput(text: "Opened Clock/Shortcuts app to set alarm for \(time) (\(label)). Please confirm in the app.")
    }

    private func decodeArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

/// Email tool — iOS does NOT let third-party apps read Mail.app data.
/// This tool opens the Mail app or composes a new email via mailto:.
public struct EmailTool: AgentTool, Sendable {

    public var name: String { "open_mail" }
    public var description: String {
        "Opens the Mail app or composes a new email. iOS does not allow third-party apps to read existing emails — this opens the system Mail app."
    }
    public var parametersJSONSchema: String { "{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\",\"description\":\"Recipient email\"},\"subject\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}}}" }
    public var riskLevel: ToolRiskLevel { .readOnly }
    public var requiresConfirmation: Bool { false }

    public init() {}

    public func execute(input: ToolInput) async throws -> ToolOutput {
        let args = try decodeArguments(input.rawJSON)
        let to = (args["to"] as? String) ?? ""
        let subject = (args["subject"] as? String) ?? ""
        let body = (args["body"] as? String) ?? ""

        var components = URLComponents(string: "mailto:\(to)")!
        var queryItems: [URLQueryItem] = []
        if !subject.isEmpty { queryItems.append(URLQueryItem(name: "subject", value: subject)) }
        if !body.isEmpty { queryItems.append(URLQueryItem(name: "body", value: body)) }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        guard let url = components.url else {
            return ToolOutput(text: "Could not construct mailto URL.")
        }

        await MainActor.run {
            UIApplication.shared.open(url)
        }

        return ToolOutput(text: "Opened Mail app" + (to.isEmpty ? "" : " to \(to)") + ".")
    }

    private func decodeArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}