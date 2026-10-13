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
        XCTAssertTrue(await registry.descriptors().isEmpty)
        await registry.register(SpyReadTool())
        await registry.register(DangerousTool())
        let descs = await registry.descriptors()
        XCTAssertEqual(descs.count, 2)
        let wipe = descs.first(where: { $0.name == "test.wipe" })
        XCTAssertEqual(wipe?.riskLevel, .destructive)
        XCTAssertEqual(wipe?.requiresConfirmation, true)
    }
}
