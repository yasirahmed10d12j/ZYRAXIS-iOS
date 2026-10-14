import XCTest
@testable import ZYRAXIS

/// Local-skills batch: offline math, conversions, web search, front pages,
/// who-is, saved places, alarms. Scripted doubles; no backend, no device.
@MainActor
final class LocalSkillsTests: XCTestCase {

    private let router = FastCommandRouter()

    private func makeManager(
        memory: InMemoryMemoryService = InMemoryMemoryService(),
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
        return (manager, scripted)
    }

    // MARK: - Evaluator units

    func testEvaluate() {
        XCTAssertEqual(FastCommandRouter.evaluate("2+3*4"), 14.0)
        XCTAssertEqual(FastCommandRouter.evaluate("(2+3)*4"), 20.0)
        XCTAssertEqual(FastCommandRouter.evaluate("10%3"), 1.0)
        XCTAssertEqual(FastCommandRouter.evaluate("-5+3"), -2.0)
        XCTAssertEqual(FastCommandRouter.evaluate("2.5*4"), 10.0)
        XCTAssertNil(FastCommandRouter.evaluate("5/0"))
        XCTAssertNil(FastCommandRouter.evaluate("2++2"))
        XCTAssertNil(FastCommandRouter.evaluate(""))
        XCTAssertNil(FastCommandRouter.evaluate("2+"))
    }

    // MARK: - Router: math + conversions

    func testMathCommands() {
        XCTAssertEqual(router.route("what is 12*8?"), .answer("= 96"))
        XCTAssertEqual(router.route("calculate (45+7)*2"), .answer("= 104"))
        XCTAssertEqual(router.route("what is love?"), .none)
        XCTAssertEqual(router.route("what is 10/0?"), .none)
        // Existing time fact must not be eaten by math.
        guard case .answer(let t) = router.route("what time is it") else {
            return XCTFail("time fact broken")
        }
        XCTAssertTrue(t.contains("time is"))
    }

    func testConversions() {
        XCTAssertEqual(router.route("convert 5 km to miles"), .answer("= 3.107 miles"))
        XCTAssertEqual(router.route("convert 32 f to c"), .answer("= 0 c"))
        XCTAssertEqual(router.route("convert 5 parsecs to miles"), .none)
        XCTAssertEqual(router.route("convert five km to miles"), .none)
    }

    // MARK: - Router: search + front pages

    func testWebSearch() {
        if case .open(let req) = router.route("google bengal cats") {
            XCTAssertTrue(req.url.absoluteString.hasPrefix("https://www.google.com/search?q="))
            XCTAssertTrue(req.url.absoluteString.contains("bengal"))
        } else { XCTFail("expected web search") }
        // YouTube search keeps priority over generic search.
        if case .open(let req) = router.route("search youtube for cats") {
            XCTAssertTrue(req.url.absoluteString.contains("youtube.com"))
        } else { XCTFail("youtube search stolen") }
        XCTAssertEqual(router.route("search my reminders"), .none)
        XCTAssertEqual(router.route("search"), .none)
    }

    func testNewFrontPages() {
        if case .open(let req) = router.route("open spotify") {
            XCTAssertEqual(req.url.absoluteString, "https://open.spotify.com/")
        } else { XCTFail("expected spotify") }
        if case .open(let req) = router.route("open google maps") {
            XCTAssertEqual(req.url.absoluteString, "https://maps.google.com/")
        } else { XCTFail("expected google maps") }
        // Apple Maps query path is untouched.
        if case .open(let req) = router.route("directions to paris") {
            XCTAssertEqual(req.kind, .maps)
        } else { XCTFail("apple maps broken") }
    }

    // MARK: - Router: who-is + places + alarm

    func testWhoIsRouting() {
        XCTAssertEqual(router.route("who is rehan"), .whoIs("rehan"))
        XCTAssertEqual(router.route("who is the president"), .none)
        XCTAssertEqual(router.route("who is albert einstein"), .none)
        XCTAssertEqual(router.route("who is"), .none)
    }

    func testSavedPlaceRouting() {
        XCTAssertEqual(router.route("directions home"), .savedPlace("home"))
        XCTAssertEqual(router.route("take me home"), .savedPlace("home"))
        XCTAssertEqual(router.route("take me to work"), .savedPlace("work"))
        XCTAssertEqual(router.route("directions to paris"), .open(OpenRequest.maps(query: "paris")!))
    }

    func testAlarmRouting() {
        if case .remind(let text, let due) = router.route("wake me up at 7") {
            XCTAssertEqual(text, "Alarm for 07:00")
            XCTAssertEqual(Calendar.current.component(.hour, from: due!), 7)
        } else { XCTFail("expected alarm reminder") }
        if case .remind(let text, let due) = router.route("set an alarm for 7:30pm") {
            XCTAssertEqual(text, "Alarm for 19:30")
            XCTAssertEqual(Calendar.current.component(.hour, from: due!), 19)
            XCTAssertEqual(Calendar.current.component(.minute, from: due!), 30)
        } else { XCTFail("expected pm alarm") }
        XCTAssertEqual(router.route("wake me up at 25"), .none)
        XCTAssertEqual(router.route("wake me up"), .none)
    }

    func testNextOccurrence() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 15; comps.hour = 10; comps.minute = 0
        let now = Calendar.current.date(from: comps)!
        let later = FastCommandRouter.nextOccurrence(hour: 12, minute: 0, now: now)
        XCTAssertEqual(Calendar.current.component(.hour, from: later), 12)
        XCTAssertEqual(Calendar.current.component(.day, from: later), 15)
        let tomorrow = FastCommandRouter.nextOccurrence(hour: 7, minute: 0, now: now)
        XCTAssertEqual(Calendar.current.component(.day, from: tomorrow), 16)
    }

    // MARK: - Engine

    func testWhoIsHitAnswersFromMemory() async {
        let memory = InMemoryMemoryService(seed: [
            MemoryItem(content: "Rehan likes cricket", tags: [], importance: 0.5)
        ])
        let (manager, scripted) = makeManager(memory: memory)
        await manager.send("who is rehan")
        XCTAssertEqual(scripted.callCount, 0)
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("cricket"))
    }

    func testWhoIsMissFallsThroughToAI() async {
        let (manager, scripted) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "AI knows", requestId: id))]
        }
        await manager.send("who is zoltan")
        XCTAssertEqual(manager.messages.filter { $0.role == .user }.count, 1, "miss must send exactly once")
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(last, "AI knows")
    }

    func testSavedPlaceHitOpensMaps() async {
        let memory = InMemoryMemoryService(seed: [
            MemoryItem(content: "my home address is 221B Baker Street", tags: [], importance: 0.5)
        ])
        let (manager, scripted) = makeManager(memory: memory)
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        await manager.send("directions home")
        XCTAssertEqual(scripted.callCount, 0)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].url.absoluteString.contains("maps.apple.com"))
        XCTAssertTrue(manager.activities.contains { $0.title == "Directions to home" })
    }

    func testSavedPlaceMissAsksForAddress() async {
        let (manager, scripted) = makeManager()
        await manager.send("directions home")
        XCTAssertEqual(scripted.callCount, 0)
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("home address"))
    }
}
