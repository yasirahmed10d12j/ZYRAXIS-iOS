import XCTest
@testable import ZYRAXIS

/// Safe local tool double: read-only, no confirmation.
/// Struct (implicitly Sendable): execution is proven by the echoed output,
/// since actor witnesses of nonisolated requirements cannot record state.
struct SpyReadTool: AgentTool {
    let name = "test.read"
    let description = "Reads test data."

    func execute(input: ToolInput) async throws -> ToolOutput {
        ToolOutput(text: "{\"echo\":" + input.rawJSON + "}")
    }
}

/// Cancellation double: cooperative cancellation must propagate through
/// the registry instead of becoming a tool failure.
struct CancellingTool: AgentTool {
    let name = "test.cancel"
    let description = "Always cancels."

    func execute(input: ToolInput) async throws -> ToolOutput {
        throw CancellationError()
    }
}

/// Dangerous tool double: must NEVER execute from a server tool_call.
/// If it ever ran, its marker output would appear in the result.
struct DangerousTool: AgentTool {
    let name = "test.wipe"
    let description = "Destructive test tool."
    let riskLevel: ToolRiskLevel = .destructive
    let requiresConfirmation = true

    func execute(input: ToolInput) async throws -> ToolOutput {
        ToolOutput(text: "{\"MARKER\":\"wipe-executed\"}")
    }
}

/// Tool round-trip: server tool_call → registry lookup → safe execution →
/// result returned. Unregistered/unsafe tools get structured refusals.
/// No backend required.
@MainActor
final class ToolRoundTripTests: XCTestCase {

    private func makeManager(
        tools: [any AgentTool] = [],
        script: @escaping (UUID) -> [AIStreamEvent]
    ) async -> (ConversationManager, ScriptedAIService) {
        let sm = AssistantStateMachine()
        let settings = SettingsStore()
        settings.selectedProvider = .mock
        let registry = DefaultToolRegistry()
        for tool in tools {
            await registry.register(tool)
        }
        let scripted = ScriptedAIService()
        scripted.builder = script
        let manager = ConversationManager(
            stateMachine: sm,
            settings: settings,
            memoryService: InMemoryMemoryService(),
            toolRegistry: registry,
            mockService: scripted,
            backendService: MockAIService(delayNanoseconds: 0)
        )
        return (manager, scripted)
    }

    func testSafeToolExecutesAndReturnsResult() async {
        let (manager, scripted) = await makeManager(tools: [SpyReadTool()]) { id in
            [.toolCall(request: ToolCallRequest(
                toolCall: ToolCall(toolName: "test.read", argumentsJSON: "{\"q\":1}"),
                requestId: id)),
             .completed(requestId: id, response: AIResponse(text: "done", requestId: id))]
        }
        await manager.send("use the tool")
        XCTAssertEqual(scripted.sentResults.count, 1)
        let result = scripted.sentResults[0]
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.toolName, "test.read")
        // Echoed arguments prove the tool executed with the right input.
        XCTAssertEqual(result.outputJSON, "{\"echo\":{\"q\":1}}")
        XCTAssertTrue(manager.activities.contains(where: { $0.title == "Tool ok: test.read" }))
    }

    func testUnregisteredToolYieldsUnsupportedResult() async {
        let (manager, scripted) = await makeManager { id in
            [.toolCall(request: ToolCallRequest(
                toolCall: ToolCall(toolName: "ghost.tool", argumentsJSON: "{}"),
                requestId: id)),
             .completed(requestId: id, response: AIResponse(text: "done", requestId: id))]
        }
        await manager.send("use a ghost")
        XCTAssertEqual(scripted.sentResults.count, 1)
        let result = scripted.sentResults[0]
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.error?.contains("unsupported tool") == true, "got: \(result.error ?? "")")
        XCTAssertTrue(manager.activities.contains(where: { $0.title.contains("Unsupported tool") }))
    }

    func testDangerousToolIsRefusedWithoutExecuting() async {
        let (manager, scripted) = await makeManager(tools: [DangerousTool()]) { id in
            [.toolCall(request: ToolCallRequest(
                toolCall: ToolCall(toolName: "test.wipe", argumentsJSON: "{}"),
                requestId: id)),
             .completed(requestId: id, response: AIResponse(text: "done", requestId: id))]
        }
        await manager.send("wipe everything")
        XCTAssertEqual(scripted.sentResults.count, 1)
        let result = scripted.sentResults[0]
        XCTAssertFalse(result.succeeded)
        // The wipe marker must never appear: the tool did not run.
        XCTAssertFalse(result.outputJSON.contains("wipe-executed"))
        XCTAssertTrue(result.error?.contains("requires confirmation") == true)
    }

    func testRegistryDescriptorsExposeMetadata() async {
        let registry = DefaultToolRegistry()
        let descriptorsEmpty = await registry.descriptors().isEmpty
        XCTAssertTrue(descriptorsEmpty)
        await registry.register(SpyReadTool())
        await registry.register(DangerousTool())
        let descs = await registry.descriptors()
        XCTAssertEqual(descs.count, 2)
        let wipe = descs.first(where: { $0.name == "test.wipe" })
        XCTAssertEqual(wipe?.riskLevel, .destructive)
        XCTAssertEqual(wipe?.requiresConfirmation, true)
    }

    func testCancellationPropagatesFromTools() async {
        let registry = DefaultToolRegistry()
        await registry.register(CancellingTool())
        do {
            _ = try await registry.execute(call: ToolCall(toolName: "test.cancel", argumentsJSON: "{}"))
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Expected: cancellation must propagate, not become a failure.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testDeviceInfoSnapshotInvariants() {
        // Real values on any device/simulator: total RAM and CPU cores always
        // exist; storage exists with free <= total when readable.
        let snap = DeviceInfoProvider.collect()
        XCTAssertFalse(snap.modelIdentifier.isEmpty)
        XCTAssertFalse(snap.osVersion.isEmpty)
        XCTAssertGreaterThanOrEqual(snap.cpuCount, 1)
        XCTAssertGreaterThan(snap.totalMemoryBytes, 0)
        if let total = snap.storageTotalBytes, let free = snap.storageFreeBytes {
            XCTAssertLessThanOrEqual(free, total)
        }
        if let level = snap.batteryLevel {
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(level, 1)
        }
    }

    func testDeviceInfoDisplayHelpers() {
        XCTAssertEqual(DeviceInfoProvider.displayBytes(nil), "—")
        XCTAssertFalse(DeviceInfoProvider.displayBytes(1024).isEmpty)
        XCTAssertEqual(DeviceInfoProvider.displayBattery(nil), "—")
        XCTAssertEqual(DeviceInfoProvider.displayBattery(0.5), "50%")
        XCTAssertEqual(DeviceInfoProvider.thermalLabel(.nominal), "nominal")
        XCTAssertEqual(DeviceInfoProvider.thermalLabel(.fair), "fair")
        XCTAssertEqual(DeviceInfoProvider.thermalLabel(.serious), "serious")
        XCTAssertEqual(DeviceInfoProvider.thermalLabel(.critical), "critical")
    }

    func testDeviceInfoToolRoundTrip() async throws {
        let registry = DefaultToolRegistry()
        await registry.register(DeviceInfoTool())
        let result = try await registry.execute(call: ToolCall(toolName: "get_device_info", argumentsJSON: "{}"))
        XCTAssertTrue(result.succeeded)
        let data = try XCTUnwrap(result.outputJSON.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(DeviceSnapshot.self, from: data)
        XCTAssertFalse(snapshot.modelIdentifier.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.cpuCount, 1)
    }

    func testNotificationToolDescriptor() {
        let tool = NotificationTool()
        XCTAssertEqual(tool.name, "get_notifications")
        XCTAssertEqual(tool.riskLevel, .readOnly)
        XCTAssertFalse(tool.requiresConfirmation)
    }

    func testAlarmToolDescriptor() {
        let tool = AlarmTool()
        XCTAssertEqual(tool.name, "set_alarm")
        XCTAssertEqual(tool.riskLevel, .reversible)
        XCTAssertTrue(tool.requiresConfirmation)
    }

    func testEmailToolDescriptor() {
        let tool = EmailTool()
        XCTAssertEqual(tool.name, "open_mail")
        XCTAssertEqual(tool.riskLevel, .readOnly)
        XCTAssertFalse(tool.requiresConfirmation)
    }

    func testAlarmToolInvalidTimeRejected() async throws {
        let registry = DefaultToolRegistry()
        await registry.register(AlarmTool())
        do {
            _ = try await registry.execute(call: ToolCall(toolName: "set_alarm", argumentsJSON: "{\"time\":\"invalid\"}"))
            XCTFail("expected ToolError for invalid time")
        } catch let e as ToolError {
            XCTAssertTrue(e.errorDescription?.contains("Invalid time format") == true, "got: \(e.errorDescription ?? "")")
        } catch {
            XCTFail("expected ToolError, got \(error)")
        }
    }

    func testAlarmToolValidTimeReturnsOpenedMessage() async throws {
        let registry = DefaultToolRegistry()
        await registry.register(AlarmTool())
        let result = try await registry.execute(call: ToolCall(toolName: "set_alarm", argumentsJSON: "{\"time\":\"07:30\",\"label\":\"test\"}"))
        // Note: actually opens Clock app; we only verify it returns success with the message
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.outputJSON.contains("Opened Clock") || result.outputJSON.contains("07:30"))
    }
}
