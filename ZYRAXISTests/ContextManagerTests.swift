import XCTest
@testable import ZYRAXIS

/// Context-engine tests: history caps, character budgets, secret-memory
/// filtering, newest-wins ordering. No backend required.
final class ContextManagerTests: XCTestCase {

    private func message(_ text: String) -> ConversationMessage {
        ConversationMessage(role: .user, text: text)
    }

    private func memory(_ content: String, tags: [String] = [], importance: Double = 0.5) -> MemoryItem {
        MemoryItem(content: content, tags: tags, importance: importance)
    }

    func testMessageCountCappedNewestWins() {
        let mgr = ContextManager(limits: ContextLimits(maxMessages: 5, maxMemories: 5, maxTotalChars: 100_000, maxMemoryChars: 10_000))
        let history = (0..<10).map { message("msg-\($0)") }
        let ctx = mgr.build(history: history, memories: [], state: .idle)
        XCTAssertEqual(ctx.messages.count, 5)
        XCTAssertEqual(ctx.messages.first?.text, "msg-5")
        XCTAssertEqual(ctx.messages.last?.text, "msg-9")
    }

    func testTotalCharsBudgetTrimsOldest() {
        let mgr = ContextManager(limits: ContextLimits(maxMessages: 20, maxMemories: 5, maxTotalChars: 10, maxMemoryChars: 1000))
        let history = [message("aaaa"), message("bbbb"), message("cc")]
        let ctx = mgr.build(history: history, memories: [], state: .idle)
        let total = ctx.messages.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, 10)
        XCTAssertEqual(ctx.messages.last?.text, "cc", "newest message must survive")
    }

    func testSecretTaggedMemoriesExcluded() {
        let mgr = ContextManager()
        let memories = [
            memory("favorite color is blue", tags: ["preference"], importance: 0.9),
            memory("api_key hunter2", tags: ["secret"], importance: 1.0),
            memory("db password xyz", tags: ["Credential"], importance: 1.0),
            memory("bearer token abc", tags: ["TOKEN"], importance: 1.0)
        ]
        let ctx = mgr.build(history: [], memories: memories, state: .idle)
        XCTAssertEqual(ctx.messages.count, 0)
        XCTAssertEqual(ctx.memories.count, 1)
        XCTAssertEqual(ctx.memories[0].content, "favorite color is blue")
    }

    func testMemoryCountAndLengthCapped() {
        let mgr = ContextManager(limits: ContextLimits(maxMessages: 20, maxMemories: 2, maxTotalChars: 100_000, maxMemoryChars: 5))
        let memories = (0..<5).map { memory("content-\($0)-long", importance: Double($0) / 10.0) }
        let ctx = mgr.build(history: [], memories: memories, state: .idle)
        XCTAssertLessThanOrEqual(ctx.memories.count, 2)
        XCTAssertTrue(ctx.memories.allSatisfy { $0.content.count <= 6 }) // 5 chars + ellipsis
    }

    func testAssistantStateAndToolsPropagated() {
        let mgr = ContextManager()
        let ctx = mgr.build(history: [], memories: [], state: .processing, availableTools: ["a", "b"], systemPrompt: "sys")
        XCTAssertEqual(ctx.assistantState, "PROCESSING")
        XCTAssertEqual(ctx.availableTools, ["a", "b"])
        XCTAssertEqual(ctx.systemPrompt, "sys")
    }

    func testNegativeMaxMessagesYieldsEmptyWithoutTrapping() {
        // Array.suffix(_:) traps on negative counts — limits must be clamped.
        let mgr = ContextManager(limits: ContextLimits(maxMessages: -5, maxMemories: 5, maxTotalChars: 1000, maxMemoryChars: 100))
        let ctx = mgr.build(history: [message("hi")], memories: [], state: .idle)
        XCTAssertTrue(ctx.messages.isEmpty)
    }

    func testExtendedSecretTagsExcluded() {
        let mgr = ContextManager()
        let memories = [
            memory("keep me", tags: ["note"], importance: 0.5),
            memory("k1", tags: ["key"], importance: 0.9),
            memory("k2", tags: ["SECRET-KEY"], importance: 0.9),
            memory("k3", tags: ["Credentials"], importance: 0.9),
            memory("k4", tags: ["bearer"], importance: 0.9)
        ]
        let ctx = mgr.build(history: [], memories: memories, state: .idle)
        XCTAssertEqual(ctx.memories.count, 1)
        XCTAssertEqual(ctx.memories.first?.content, "keep me")
    }
}
