import XCTest
@testable import ZYRAXIS

/// Server-pushed commands (dashboard → device): protocol decode, adapter
/// scoping, and engine routing. No backend required (scripted doubles).
@MainActor
final class RemoteCommandTests: XCTestCase {

    private func makeManager(
        builder: @escaping (UUID) -> [AIStreamEvent] = { _ in [] }
    ) -> (ConversationManager, ScriptedAIService) {
        let sm = AssistantStateMachine()
        let settings = SettingsStore()
        settings.selectedProvider = .mock
        let scripted = ScriptedAIService()
        scripted.builder = builder
        let manager = ConversationManager(
            stateMachine: sm,
            settings: settings,
            memoryService: InMemoryMemoryService(),
            toolRegistry: DefaultToolRegistry(),
            mockService: scripted,
            backendService: MockAIService(delayNanoseconds: 0)
        )
        return (manager, scripted)
    }

    // MARK: - Protocol

    func testRemoteCommandTypeRoundTrip() {
        XCTAssertEqual(BackendMessageType.from(rawValue: "remote_command"), .remoteCommand)
        XCTAssertEqual(BackendMessageType.remoteCommand.rawValue, "remote_command")
    }

    func testRemoteCommandPayloadDecodes() throws {
        let env = ZyraxisEnvelope(
            type: .remoteCommand,
            requestId: "77777777-7777-7777-7777-777777777777",
            payload: ["command": .string("open youtube")]
        )
        // JSON round-trip like a real frame off the socket.
        let text = try env.encode()
        let decoded = try ZyraxisEnvelope.decode(text)
        XCTAssertEqual(decoded.type, .remoteCommand)
        let payload = try decoded.decodePayload(RemoteCommandPayload.self)
        XCTAssertEqual(payload.command, "open youtube")
    }

    func testAdapterIgnoresRemoteCommandInRequestScope() throws {
        let env = ZyraxisEnvelope(
            type: .remoteCommand,
            requestId: UUID().uuidString,
            payload: ["command": .string("open youtube")]
        )
        let events = try ZyraxisV1Adapter().streamEvents(from: env)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Engine routing

    func testHandleRemoteCommandOpensYouTube() async {
        let (manager, _) = makeManager()
        var opened: OpenRequest?
        manager.openURLHandler = { opened = $0 }
        await manager.handleRemoteCommand("open youtube")
        XCTAssertEqual(opened?.url.absoluteString, "https://www.youtube.com/")
        XCTAssertTrue(manager.activities.contains { $0.title == "Remote command from server" })
        XCTAssertTrue(manager.messages.contains { $0.role == .user && $0.text == "open youtube" })
    }

    func testHandleRemoteCommandEmptyIgnored() async {
        let (manager, _) = makeManager()
        await manager.handleRemoteCommand("   ")
        XCTAssertTrue(manager.messages.isEmpty)
        XCTAssertTrue(manager.activities.isEmpty)
    }

    func testHandleRemoteCommandFallsThroughToAI() async {
        let (manager, _) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "dragon tale", requestId: id))]
        }
        await manager.handleRemoteCommand("tell me a story about dragons")
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(last, "dragon tale")
    }
}
