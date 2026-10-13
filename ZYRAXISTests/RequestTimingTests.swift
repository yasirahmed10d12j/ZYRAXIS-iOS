import XCTest
@testable import ZYRAXIS

/// Latency instrumentation: monotonic T0…T4 timing recorded per request,
/// exposed for DEBUG diagnostics. No backend required.
@MainActor
final class RequestTimingTests: XCTestCase {

    private func makeManager(_ scripted: ScriptedAIService) -> ConversationManager {
        let settings = SettingsStore()
        settings.selectedProvider = .mock
        return ConversationManager(
            stateMachine: AssistantStateMachine(),
            settings: settings,
            memoryService: InMemoryMemoryService(),
            toolRegistry: DefaultToolRegistry(),
            mockService: scripted,
            backendService: MockAIService(delayNanoseconds: 0)
        )
    }

    func testTimingRecordedOnCompletion() async throws {
        let scripted = ScriptedAIService()
        scripted.builder = { id in
            [.thinking(requestId: id),
             .textDelta(requestId: id, delta: "hi", seq: 1),
             .completed(requestId: id, response: AIResponse(text: "hi", requestId: id))]
        }
        let manager = makeManager(scripted)
        XCTAssertNil(manager.lastTiming)
        await manager.send("hello")
        let timing = try? XCTUnwrap(manager.lastTiming)
        let t = try XCTUnwrap(timing)
        XCTAssertNotNil(t.t1Accepted)
        XCTAssertNotNil(t.t2FirstDelta)
        XCTAssertNotNil(t.t3LastDelta)
        XCTAssertNotNil(t.t4Done)
        XCTAssertNotNil(t.timeToFirstToken)
        XCTAssertNotNil(t.streamDuration)
        XCTAssertNotNil(t.totalResponseTime)
        XCTAssertGreaterThanOrEqual(t.timeToFirstToken!, .zero)
        XCTAssertGreaterThanOrEqual(t.totalResponseTime!, .zero)
    }

    func testTimingRecordedOnCancellation() async {
        let scripted = ScriptedAIService()
        scripted.hangAfterIndex = 1
        scripted.hangNanoseconds = 5_000_000_000
        scripted.builder = { id in
            [.thinking(requestId: id),
             .textDelta(requestId: id, delta: "P1", seq: 1),
             .completed(requestId: id, response: AIResponse(text: "P1", requestId: id))]
        }
        let manager = makeManager(scripted)
        let task = Task { await manager.send("hang") }
        let deadline = Date().addingTimeInterval(3)
        while manager.messages.allSatisfy({ $0.text != "P1" }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        manager.cancel()
        await task.value
        XCTAssertNotNil(manager.lastTiming?.t4Done)
    }

    func testDurationDisplayStrings() {
        XCTAssertEqual(Duration.milliseconds(250).displayString, "250 ms")
        XCTAssertEqual(Duration.seconds(2).displayString, "2.00 s")
    }

    func testSanitizedHostStripsCredentials() {
        XCTAssertEqual(
            DiagnosticsSupport.sanitizedHostString(for: URL(string: "https://user:pass@api.example.com:8443/chat?q=1")),
            "https://api.example.com:8443"
        )
        XCTAssertEqual(
            DiagnosticsSupport.sanitizedHostString(for: URL(string: "wss://live.example.com/socket")),
            "wss://live.example.com"
        )
        XCTAssertEqual(DiagnosticsSupport.sanitizedHostString(for: nil), "—")
        let dirty = DiagnosticsSupport.sanitizedHostString(for: URL(string: "https://user:pass@h.example.com/"))
        XCTAssertFalse(dirty.contains("user"))
        XCTAssertFalse(dirty.contains("pass"))
    }
}
