import XCTest
@testable import ZYRAXIS

/// Quiz mode + study briefing: router mapping and engine behavior.
/// Scripted AI doubles; no backend, no device required.
@MainActor
final class StudyTests: XCTestCase {

    private let router = FastCommandRouter()

    private func makeManager(
        memory: InMemoryMemoryService = InMemoryMemoryService(),
        tasks: (any TaskService)? = nil,
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
            memoryService: memory,
            toolRegistry: DefaultToolRegistry(),
            mockService: scripted,
            backendService: MockAIService(delayNanoseconds: 0)
        )
        manager.taskService = tasks
        return (manager, scripted)
    }

    // MARK: - Router

    func testQuizStartRouting() {
        XCTAssertEqual(router.route("quiz me on capitals"), .quizStart("capitals"))
        XCTAssertEqual(router.route("test me on verbs"), .quizStart("verbs"))
        XCTAssertEqual(router.route("ask me questions about fractions"), .quizStart("fractions"))
        XCTAssertEqual(router.route("stop quiz"), .quizStop)
        XCTAssertEqual(router.route("end quiz"), .quizStop)
        XCTAssertEqual(router.route("quiz score"), .quizScore)
        XCTAssertEqual(router.route("my score"), .quizScore)
        guard case .answer(let hint) = router.route("quiz me") else {
            return XCTFail("expected quiz usage hint")
        }
        XCTAssertTrue(hint.contains("quiz me on"))
        guard case .answer(let hint2) = router.route("quiz") else {
            return XCTFail("expected quiz usage hint for bare quiz")
        }
        XCTAssertTrue(hint2.contains("quiz me on"))
    }

    func testBriefRouting() {
        XCTAssertEqual(router.route("morning brief"), .brief)
        XCTAssertEqual(router.route("brief me"), .brief)
        XCTAssertEqual(router.route("daily brief"), .brief)
        XCTAssertEqual(router.route("briefing"), .brief)
    }

    // MARK: - Quiz engine

    func testQuizStartAsksFirstQuestion() async {
        let (manager, scripted) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "What is the capital of France?", requestId: id))]
        }
        await manager.send("quiz me on capitals")
        XCTAssertEqual(scripted.callCount, 1)
        XCTAssertEqual(manager.quiz?.topic, "capitals")
        XCTAssertEqual(manager.quiz?.asked, 1)
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(last, "What is the capital of France?")
    }

    func testQuizAnswerGradesAndStripsMarker() async {
        var turn = 0
        let (manager, scripted) = makeManager { id in
            turn += 1
            if turn == 1 {
                return [.completed(requestId: id, response: AIResponse(text: "What is 2+2?", requestId: id))]
            }
            return [.completed(requestId: id, response: AIResponse(text: "Correct! Well done.\nSCORE:1", requestId: id))]
        }
        await manager.send("quiz me on math")
        await manager.send("4")
        XCTAssertEqual(scripted.callCount, 2)
        XCTAssertEqual(manager.quiz?.asked, 2)
        XCTAssertEqual(manager.quiz?.correct, 1)
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertFalse(last.contains("SCORE"), "marker must be stripped, got: \(last)")
        XCTAssertTrue(last.contains("Correct!"))
        // Grading prompt (not raw chat) must reach the model.
        XCTAssertTrue(scripted.lastRequest?.text.contains("SCORE:1") ?? false)
    }

    func testQuizWrongAnswerScoresZero() async {
        var turn = 0
        let (manager, _) = makeManager { id in
            turn += 1
            if turn == 1 {
                return [.completed(requestId: id, response: AIResponse(text: "Q1?", requestId: id))]
            }
            return [.completed(requestId: id, response: AIResponse(text: "Not quite.\nSCORE:0", requestId: id))]
        }
        await manager.send("quiz me on math")
        await manager.send("5")
        XCTAssertEqual(manager.quiz?.asked, 2)
        XCTAssertEqual(manager.quiz?.correct, 0)
    }

    func testQuizScoreAndStop() async {
        let (manager, scripted) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "Q1?", requestId: id))]
        }
        await manager.send("quiz me on math")
        await manager.send("quiz score")
        let score = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(score.contains("0 out of 1"))
        await manager.send("stop quiz")
        XCTAssertNil(manager.quiz)
        let over = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(over.contains("Quiz over"))
        XCTAssertEqual(scripted.callCount, 1, "score/stop must not call the AI")
    }

    func testStopWithoutQuiz() async {
        let (manager, scripted) = makeManager()
        await manager.send("stop quiz")
        XCTAssertEqual(scripted.callCount, 0)
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("No quiz running"))
    }

    // MARK: - Briefing

    func testBriefComposesOffline() async {
        let memory = InMemoryMemoryService(seed: [
            MemoryItem(content: "Rehan's phone number: 03001234567", tags: [], importance: 0.5)
        ])
        var tasks = SpyTaskService()
        tasks.active = [ZyraxisTask(title: "Pay bill", priority: .high)]
        let (manager, scripted) = makeManager(memory: memory, tasks: tasks)
        await manager.send("morning brief")
        XCTAssertEqual(scripted.callCount, 0, "briefing must not call the AI service")
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("Today is"))
        XCTAssertTrue(last.contains("Pay bill"))
        XCTAssertTrue(last.contains("Rehan"))
        XCTAssertTrue(last.contains("quiz me on"))
    }

    func testBriefEmptyState() async {
        let (manager, scripted) = makeManager(tasks: SpyTaskService())
        await manager.send("brief me")
        XCTAssertEqual(scripted.callCount, 0)
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("No active reminders"))
    }
}

/// Minimal TaskService double: canned active list, everything else refused.
/// Struct (value semantics) so Sendable conformance is automatic.
struct SpyTaskService: TaskService {
    var active: [ZyraxisTask] = []

    func create(title: String, notes: String?, dueDate: Date?, priority: ZyraxisTask.Priority) async throws -> ZyraxisTask {
        throw TaskError.emptyTitle
    }

    func list(filter: TaskFilter) async throws -> [ZyraxisTask] {
        switch filter {
        case .active:
            return active
        default:
            return []
        }
    }

    func update(id: UUID, title: String?, notes: String?, dueDate: Date?, priority: ZyraxisTask.Priority?) async throws -> ZyraxisTask {
        throw TaskError.notFound
    }

    func cancel(id: UUID) async throws -> ZyraxisTask {
        throw TaskError.notFound
    }

    func complete(id: UUID) async throws -> ZyraxisTask {
        throw TaskError.notFound
    }

    func snooze(id: UUID, until: Date) async throws -> ZyraxisTask {
        throw TaskError.notFound
    }
}
