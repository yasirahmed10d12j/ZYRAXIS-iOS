import Foundation
import UIKit

/// Device facts for the Settings device section and the `get_device_info`
/// tool. Every value comes from a real iOS API — anything iOS does not
/// expose is absent by design, never fabricated:
///
/// - CPU frequency: NO API exists (any number would be fake — omitted).
/// - System-wide free/used RAM: NO API exists. Shown instead: total physical
///   RAM plus this app's own footprint (Mach task info, real).
/// - Network throughput: NOT measured (would need a real download and mobile
///   data; connection state already lives in the Connection section).
public struct DeviceSnapshot: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var osVersion: String
    public var appVersion: String
    public var cpuCount: Int
    public var totalMemoryBytes: UInt64
    public var appFootprintBytes: UInt64?
    public var storageTotalBytes: UInt64?
    public var storageFreeBytes: UInt64?
    /// 0...1, or nil when unknown (e.g. simulator without a battery).
    public var batteryLevel: Float?
    public var batteryState: String
    public var thermalState: String
    public var lowPowerMode: Bool
}

public enum DeviceInfoProvider {

    public static func collect() -> DeviceSnapshot {
        let context = DeviceContext.current()
        let battery = batterySnapshot()
        let storage = storageSnapshot()
        return DeviceSnapshot(
            modelIdentifier: context.deviceModel ?? UIDevice.current.model,
            osVersion: context.osVersion ?? ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: context.appVersion ?? "unknown",
            cpuCount: ProcessInfo.processInfo.processorCount,
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            appFootprintBytes: appFootprintBytes(),
            storageTotalBytes: storage.total,
            storageFreeBytes: storage.free,
            batteryLevel: battery.level,
            batteryState: battery.state,
            thermalState: thermalLabel(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// This app's resident footprint via Mach task info. Nil when unreadable.
    public static func appFootprintBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private static func storageSnapshot() -> (total: UInt64?, free: UInt64?) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let total = attrs[.systemSize] as? NSNumber,
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return (nil, nil)
        }
        return (total.uint64Value, free.uint64Value)
    }

    private static func batterySnapshot() -> (level: Float?, state: String) {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        case .unknown: state = "unknown"
        @unknown default: state = "unknown"
        }
        device.isBatteryMonitoringEnabled = wasMonitoring
        return (level >= 0 ? level : nil, state)
    }

    public static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    public static func displayBytes(_ bytes: UInt64?) -> String {
        guard let bytes else {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    public static func displayBattery(_ level: Float?) -> String {
        guard let level else {
            return "—"
        }
        return String(format: "%.0f%%", Double(level) * 100)
    }
}

/// Safe read-only device-info tool for backend/E2E tool round-trips.
/// Same honesty contract as `AppInfoTool`: metadata only, no identifiers,
/// no private data. Never add destructive tools to this client.
public struct DeviceInfoTool: AgentTool, Sendable {

    public var name: String { "get_device_info" }
    public var description: String {
        "Returns non-sensitive device facts: model, OS/app version, CPU cores, memory, storage, battery, thermal state."
    }
    public var parametersJSONSchema: String { "{\"type\":\"object\",\"properties\":{}}" }
    public var riskLevel: ToolRiskLevel { .readOnly }
    public var requiresConfirmation: Bool { false }

    public init() {}

    public func execute(input: ToolInput) async throws -> ToolOutput {
        let data = try JSONEncoder().encode(DeviceInfoProvider.collect())
        return ToolOutput(text: String(data: data, encoding: .utf8) ?? "{}")
    }
}
