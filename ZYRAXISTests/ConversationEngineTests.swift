import XCTest
@testable import ZYRAXIS

/// Deterministic scripted backend double. Echoes the engine's request ID in
/// every event (like a real backend must), so stale/duplicate guards apply.
@MainActor
final class ScriptedAIService: AIService {

    let provider: AIProvider = .mock
    var callCount = 0
    var builder: (UUID) -> [AIStreamEvent] = { _ in [] }
    var failWith: Error?
    /// Sleep `hangNanoseconds` before yielding the event at `hangAfterIndex`.
    var hangAfterIndex: Int?
    var hangNanoseconds: UInt64 = 0
    /// Tool results the engine sent back (tool round-trip observation).
    var sentResults: [ToolCallResult] = []
    /// Last request received (context/memory/timing observation).
    var lastRequest: AIRequest?

    func sendToolResult(_ result: ToolCallResult) async {
        sentResults.append(result)
    }

    func sendMessage(_ request: AIRequest) async throws -> AIResponse {
        callCount += 1
        if let failWith { throw failWith }
        return AIResponse(text: "scripted", requestId: request.id)
    }

    func streamMessage(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { continuation in
            Task {
                self.callCount += 1
                do {
                    if let failWith = self.failWith {
                        throw failWith
                    }
                    let events = self.builder(request.id)
                    for (i, event) in events.enumerated() {
                        if self.hangAfterIndex == i {
                            try await Task.sleep(nanoseconds: self.hangNanoseconds)
                        }
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Conversation-engine tests: ordering, accumulation, dedup, stale-guard,
/// cancellation, tool states, errors, fast path. No backend required.
@MainActor
final class ConversationEngineTests: XCTestCase {

    private func makeManager(
        builder: @escaping (UUID) -> [AIStreamEvent] = { _ in [] },
        failWith: Error? = nil
    ) -> (ConversationManager, ScriptedAIService, AssistantStateMachine, SettingsStore) {
        let sm = AssistantStateMachine()
        let settings = SettingsStore()
        settings.selectedProvider = .mock
        let scripted = ScriptedAIService()
        scripted.builder = builder
        scripted.failWith = failWith
        let manager = ConversationManager(
            stateMachine: sm,
            settings: settings,
            memoryService: InMemoryMemoryService(),
            toolRegistry: DefaultToolRegistry(),
            mockService: scripted,
            backendService: MockAIService(delayNanoseconds: 0)
        )
        return (manager, scripted, sm, settings)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Streaming accumulation

    func testStreamingAccumulatesInOrder() async {
        let (manager, _, sm, _) = makeManager { id in
            [.connected(requestId: id),
             .thinking(requestId: id),
             .textDelta(requestId: id, delta: "Hel", seq: 1),
             .textDelta(requestId: id, delta: "lo ", seq: 2),
             .textDelta(requestId: id, delta: "ZYRAXIS", seq: 3),
             .completed(requestId: id, response: AIResponse(text: "Hello ZYRAXIS", requestId: id))]
        }
        await manager.send("Hello ZYRAXIS")
        let assistants = manager.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants[0].text, "Hello ZYRAXIS")
        XCTAssertFalse(assistants[0].isStreaming)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertTrue(sm.stateHistory.contains(.processing))
        XCTAssertTrue(sm.stateHistory.contains(.speaking))
    }

    func testDuplicateSeqDropped() async {
        let (manager, _, _, _) = makeManager { id in
            [.textDelta(requestId: id, delta: "A", seq: 1),
             .textDelta(requestId: id, delta: "A-DUP", seq: 1),
             .textDelta(requestId: id, delta: "B", seq: 2),
             .completed(requestId: id, response: AIResponse(text: "", requestId: id))]
        }
        await manager.send("go")
        let text = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(text, "AB")
    }

    func testStaleRequestIdIgnored() async {
        let (manager, _, _, _) = makeManager { id in
            [.textDelta(requestId: UUID(), delta: "STALE", seq: 1),
             .textDelta(requestId: id, delta: "fresh", seq: 1),
             .completed(requestId: id, response: AIResponse(text: "fresh", requestId: id))]
        }
        await manager.send("go")
        let text = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(text, "fresh")
        XCTAssertFalse(text.contains("STALE"))
    }

    // MARK: - Cancellation

    func testCancelStopsUpdatesAndReturnsToIdle() async {
        let sm2 = AssistantStateMachine()
        let settings2 = SettingsStore()
        settings2.selectedProvider = .mock
        let scripted = ScriptedAIService()
        scripted.hangAfterIndex = 2
        scripted.hangNanoseconds = 5_000_000_000
        scripted.builder = { id in
            [.thinking(requestId: id),
             .textDelta(requestId: id, delta: "P1", seq: 1),
             .textDelta(requestId: id, delta: "P2", seq: 2),
             .completed(requestId: id, response: AIResponse(text: "P1P2", requestId: id))]
        }
        let manager2 = ConversationManager(
            stateMachine: sm2,
            settings: settings2,
            memoryService: InMemoryMemoryService(),
            toolRegistry: DefaultToolRegistry(),
            mockService: scripted,
            backendService: MockAIService(delayNanoseconds: 0)
        )
        let sendTask = Task { await manager2.send("hang test") }
        await waitFor({ manager2.messages.contains(where: { $0.text == "P1" }) })
        XCTAssertTrue(manager2.messages.contains(where: { $0.text == "P1" }), "P1 should have streamed before cancel")
        manager2.cancel()
        await sendTask.value
        XCTAssertEqual(sm2.state, .idle)
        XCTAssertFalse(manager2.isStreaming)
        // A cancelled request must never update the UI afterward.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let text = manager2.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertFalse(text.contains("P2"), "post-cancel chunks must not land, got: \(text)")
    }

    // MARK: - Tools, errors, fast path

    func testToolCallDrivesExecutingAndActivities() async {
        let call = ToolCall(toolName: "reminder.create", argumentsJSON: "{}")
        let (manager, _, sm, _) = makeManager { id in
            [.thinking(requestId: id),
             .toolCall(request: ToolCallRequest(toolCall: call, requestId: id)),
             .toolResult(result: ToolCallResult(requestId: id, toolName: "reminder.create", outputJSON: "{\"ok\":true}")),
             .completed(requestId: id, response: AIResponse(text: "Reminder set.", requestId: id))]
        }
        await manager.send("remind me")
        XCTAssertEqual(sm.state, .idle)
        XCTAssertTrue(sm.stateHistory.contains(.executing), "tool_call must move through EXECUTING")
        XCTAssertTrue(manager.activities.contains(where: { $0.title.contains("reminder.create") }))
        XCTAssertTrue(manager.activities.contains(where: { $0.title.contains("Tool ok") }))
    }

    func testFailureSurfacesFriendlyError() async {
        let (manager, scripted, sm, _) = makeManager(
            builder: { _ in [] },
            failWith: NetworkError.timeout
        )
        await manager.send("will fail")
        XCTAssertEqual(sm.state, .error)
        let system = manager.messages.last(where: { $0.role == .system })?.text ?? ""
        XCTAssertTrue(system.lowercased().contains("took too long"), "got: \(system)")
        XCTAssertGreaterThan(scripted.callCount, 0)
        // Recovery: a new send resets from ERROR.
        scripted.failWith = nil
        scripted.builder = { id in
            [.completed(requestId: id, response: AIResponse(text: "recovered", requestId: id))]
        }
        await manager.send("again")
        XCTAssertEqual(sm.state, .idle)
    }

    func testFastCommandBypassesAI() async {
        let (manager, scripted, sm, _) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "SHOULD NOT HAPPEN", requestId: id))]
        }
        await manager.send("what time is it")
        XCTAssertEqual(scripted.callCount, 0, "fast path must not call the AI service")
        let text = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(text.lowercased().contains("current time"), "got: \(text)")
        XCTAssertEqual(sm.state, .idle)
    }

    func testMessageOrderingUserThenAssistant() async {
        let (manager, _, _, _) = makeManager { id in
            [.textDelta(requestId: id, delta: "x", seq: 1),
             .completed(requestId: id, response: AIResponse(text: "x", requestId: id))]
        }
        await manager.send("first")
        await manager.send("second")
        let roles = manager.messages.map { $0.role }
        XCTAssertEqual(roles, [.user, .assistant, .user, .assistant])
    }

    func testOpenCommandCallsHandlerWithoutAI() async {
        let (manager, scripted, sm, _) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "SHOULD NOT HAPPEN", requestId: id))]
        }
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        await manager.send("directions to paris")
        XCTAssertEqual(scripted.callCount, 0, "open path must not call the AI service")
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].kind, .maps)
        XCTAssertEqual(opened[0].url.host ?? "", "maps.apple.com")
        XCTAssertTrue(manager.activities.contains(where: { $0.title.contains("Opening") }))
        XCTAssertEqual(sm.state, .idle)
    }

    func testUnsupportedOpenFallsThroughToAI() async {
        // "open settings" has no public URL scheme: no handler call, and the
        // message still reaches the engine like normal conversation.
        let (manager, _, _, _) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "ok", requestId: id))]
        }
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        await manager.send("open settings")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(manager.messages.contains(where: { $0.role == .user && $0.text == "open settings" }))
    }

    func testYouTubeCommandUsesHTTPSWithoutAIFallback() async {
        // Recognized open command: exactly one handler call, no AI request,
        // and no youtube:// custom scheme anywhere in the URL.
        let (manager, scripted, _, _) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "SHOULD NOT HAPPEN", requestId: id))]
        }
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        await manager.send("Open YouTube")
        XCTAssertEqual(scripted.callCount, 0, "recognized open must not call the AI service")
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].url.absoluteString, "https://www.youtube.com/")
        XCTAssertFalse(opened[0].url.absoluteString.hasPrefix("youtube://"))
    }

    func testCallContactResolvesThroughDirectory() async {
        let (manager, scripted, _, _) = makeManager()
        let directory = SpyContactService()
        directory.numbersByName = ["mom": "15551234567"]
        manager.contactService = directory
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        await manager.send("call mom")
        XCTAssertEqual(scripted.callCount, 0, "contact commands must not call the AI service")
        XCTAssertTrue(directory.requestedPermission)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].url.absoluteString, "tel:15551234567")
        XCTAssertTrue(manager.activities.contains(where: { $0.title.contains("Opening") }))
    }

    func testCallContactUnknownNameReportsError() async {
        let (manager, scripted, _, _) = makeManager()
        let directory = SpyContactService()
        manager.contactService = directory
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        await manager.send("call nobody here")
        XCTAssertEqual(scripted.callCount, 0)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(manager.activities.contains(where: { $0.title.contains("Couldn't find") }))
    }

    func testHandsFreeRelistensAfterVoiceTurn() async {
        let (manager, scripted, _, settings) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "hi", requestId: id))]
        }
        settings.handsFreeMode = true
        var relistens = 0
        manager.autoListenHandler = { relistens += 1 }
        await manager.acceptExternalTranscript("hello", isFinal: true)
        XCTAssertEqual(scripted.callCount, 1)
        XCTAssertEqual(relistens, 1, "voice turn completion must re-arm the mic once")
    }

    func testTypedTurnDoesNotRelisten() async {
        let (manager, _, _, settings) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "hi", requestId: id))]
        }
        settings.handsFreeMode = true
        var relistens = 0
        manager.autoListenHandler = { relistens += 1 }
        await manager.send("typed, not spoken")
        XCTAssertEqual(relistens, 0, "typed turns must never reopen the mic")
    }

    func testExportTextFormatsTranscript() async {
        let (manager, _, _, _) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "hi back", requestId: id))]
        }
        await manager.send("hello")
        let text = manager.exportText()
        XCTAssertTrue(text.contains("[USER]"))
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("[ASSISTANT]"))
        XCTAssertTrue(text.contains("hi back"))
    }
}
