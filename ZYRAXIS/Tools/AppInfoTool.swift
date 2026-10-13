import Foundation

/// Safe read-only E2E validation tool: returns non-sensitive app identity.
///
/// No parameters, no device control, no private data — only the app name,
/// version/build, device model identifier (e.g. "iPhone12,5", no serials),
/// and OS version. Safe for a backend to invoke during tool round-trip tests.
/// Never add destructive tools to this client.
public struct AppInfoTool: AgentTool, Sendable {

    public var name: String { "get_app_info" }
    public var description: String {
        "Returns non-sensitive app identity: name, version, build, device model, OS version."
    }
    public var parametersJSONSchema: String { "{\"type\":\"object\",\"properties\":{}}" }
    public var riskLevel: ToolRiskLevel { .readOnly }
    public var requiresConfirmation: Bool { false }

    public init() {}

    public func execute(input: ToolInput) async throws -> ToolOutput {
        // Nonisolated-safe facts only: Bundle/ProcessInfo/utsname need no
        // MainActor and expose nothing private.
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let payload: [String: String] = [
            "app": "ZYRAXIS",
            "version": version,
            "build": build,
            "deviceModel": Self.deviceModel(),
            "os": os
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            ?? Data("{\"app\":\"ZYRAXIS\"}".utf8)
        return ToolOutput(text: String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { chars in
                String(cString: chars)
            }
        }
    }
}
