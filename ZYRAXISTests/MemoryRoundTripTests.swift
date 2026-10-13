import XCTest
@testable import ZYRAXIS

/// Memory round-trip through the real engine: seeded memories reach the AI
/// request context bounded and secret-filtered; disabled memory sends none.
/// No backend required (scripted service observes the request).
@MainActor
final class MemoryRoundTripTests: XCTestCase {

    private func makeManager(
        seed: [MemoryItem],
        memoryEnabled: Bool,
        scripted: ScriptedAIService
    ) -> ConversationManager {
        let settings = SettingsStore()
        settings.selectedProvider = .mock
        settings.memoryEnabled = memoryEnabled
        return ConversationManager(
            stateMachine: AssistantStateMachine(),
            settings: settings,
            memoryService: InMemoryMemoryService(seed: seed),
            toolRegistry: DefaultToolRegistry(),
            mockService: scripted,
            backendService: MockAIService(delayNanoseconds: 0)
        )
    }

    private func scriptedDone() -> ScriptedAIService {
        let s = ScriptedAIService()
        s.builder = { id in
            [.completed(requestId: id, response: AIResponse(text: "ok", requestId: id))]
        }
        return s
    }

    func testRelevantMemoriesReachContext() async {
        let scripted = scriptedDone()
        let manager = makeManager(
            seed: [MemoryItem(content: "User likes blue consoles", tags: ["pref"], importance: 0.9)],
            memoryEnabled: true,
            scripted: scripted
        )
        await manager.send("blue consoles")
        let mems = scripted.lastRequest?.context.memories ?? []
        XCTAssertEqual(mems.count, 1)
        XCTAssertTrue(mems[0].content.contains("blue"))
    }

    func testSecretMemoriesNeverSent() async {
        let scripted = scriptedDone()
        let manager = makeManager(
            seed: [
                MemoryItem(content: "api key hunter2", tags: ["secret"], importance: 1.0),
                MemoryItem(content: "blue consoles", tags: ["pref"], importance: 0.1)
            ],
            memoryEnabled: true,
            scripted: scripted
        )
        await manager.send("blue")
        let mems = scripted.lastRequest?.context.memories ?? []
        XCTAssertFalse(mems.contains(where: { $0.content.contains("hunter2") }))
    }

    func testDisabledMemorySendsNone() async {
        let scripted = scriptedDone()
        let manager = makeManager(
            seed: [MemoryItem(content: "blue consoles", tags: [], importance: 0.9)],
            memoryEnabled: false,
            scripted: scripted
        )
        await manager.send("blue consoles")
        XCTAssertEqual(scripted.lastRequest?.context.memories.count, 0)
    }

    func testMemoryCountBoundedByLimits() async {
        let scripted = scriptedDone()
        let seed = (0..<30).map {
            MemoryItem(content: "fact number \($0) about consoles", tags: [], importance: 0.5)
        }
        let manager = makeManager(seed: seed, memoryEnabled: true, scripted: scripted)
        await manager.send("consoles")
        let count = scripted.lastRequest?.context.memories.count ?? 99
        XCTAssertLessThanOrEqual(count, ContextLimits.default.maxMemories)
    }
}
