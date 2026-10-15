import XCTest
@testable import ZYRAXIS

/// Memory commands + new system-app opens + torch: router mapping and engine
/// execution. Scripted AI doubles; no backend, no device required.
@MainActor
final class MemoryCommandsTests: XCTestCase {

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

    // MARK: - Router: phone-number facts

    func testContactNumberFact() {
        let r1 = FastCommandRouter.contactNumberFact(in: "rehan's number is 03001234567")
        XCTAssertEqual(r1?.name, "rehan")
        XCTAssertEqual(r1?.digits, "03001234567")
        let r2 = FastCommandRouter.contactNumberFact(in: "remember mom's mobile number is +1 5551234567")
        XCTAssertEqual(r2?.name, "mom")
        XCTAssertEqual(r2?.digits, "+15551234567")
        XCTAssertNil(FastCommandRouter.contactNumberFact(in: "what is mom's number?"))
        XCTAssertNil(FastCommandRouter.contactNumberFact(in: "call 123"))
    }

    func testMissingDigitsAsksHonestly() {
        let action = router.route("this is rehan's number remember it in memory")
        guard case .answer(let text) = action else {
            return XCTFail("expected digits-request answer, got \(action)")
        }
        XCTAssertTrue(text.contains("Rehan"))
        // Plain questions must still reach the AI.
        XCTAssertEqual(router.route("what is mom's number?"), .none)
        XCTAssertEqual(router.route("do you remember me?"), .none)
        XCTAssertEqual(router.route("remember when we met"), .none)
    }

    func testGenericRememberNotes() {
        XCTAssertEqual(router.route("remember that my birthday is june 5"), .remember("my birthday is june 5"))
        XCTAssertEqual(router.route("note that the gate code is 4455"), .remember("the gate code is 4455"))
        XCTAssertEqual(router.route("remember my cat in memory"), .remember("my cat"))
        XCTAssertEqual(router.route("remember"), .none)
    }

    // MARK: - Router: new opens + honesty answers

    func testMessagesMailFaceTimeOpens() {
        if case .open(let req) = router.route("open messages") {
            XCTAssertEqual(req.url.absoluteString, "sms:")
        } else { XCTFail("expected messages composer") }
        if case .open(let req) = router.route("open mail") {
            XCTAssertEqual(req.url.absoluteString, "mailto:")
        } else { XCTFail("expected mail composer") }
        if case .open(let req) = router.route("open facetime") {
            XCTAssertEqual(req.url.absoluteString, "facetime://")
        } else { XCTFail("expected facetime front") }
        // Existing narrow behavior is preserved.
        XCTAssertEqual(router.route("text"), .none)
        XCTAssertEqual(router.route("call"), .none)
        XCTAssertEqual(router.route("email nodomain"), .none)
        XCTAssertEqual(router.route("open settings"), .none)
    }

    func testPhoneAndVolumeHonesty() {
        guard case .answer(let phone) = router.route("open phone") else {
            return XCTFail("expected phone honesty answer")
        }
        XCTAssertTrue(phone.contains("keypad"))
        guard case .answer(let vol) = router.route("volume") else {
            return XCTFail("expected volume honesty answer")
        }
        XCTAssertTrue(vol.contains("side buttons"))
    }

    func testTorchCommands() {
        XCTAssertEqual(router.route("flashlight on"), .system(.torch(true)))
        XCTAssertEqual(router.route("torch off"), .system(.torch(false)))
        XCTAssertEqual(router.route("turn on flashlight"), .system(.torch(true)))
        guard case .answer(let hint) = router.route("flashlight") else {
            return XCTFail("expected torch usage hint")
        }
        XCTAssertTrue(hint.contains("flashlight off"))
    }

    // MARK: - Engine

    func testRememberNoteSavesToMemory() async {
        let memory = InMemoryMemoryService()
        let (manager, scripted) = makeManager(memory: memory)
        await manager.send("remember that my cat is fluffy")
        XCTAssertEqual(scripted.callCount, 0, "memory commands must not call the AI service")
        let found = try? await memory.search(query: "fluffy", limit: 5)
        XCTAssertEqual(found?.count, 1)
        XCTAssertTrue(manager.activities.contains { $0.title == "Saved to memory" })
    }

    func testRememberPhoneThenCallByName() async {
        let memory = InMemoryMemoryService()
        let (manager, scripted) = makeManager(memory: memory)
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        await manager.send("rehan's number is 03001234567")
        XCTAssertTrue(manager.activities.contains { $0.title == "Saved Rehan's number" })
        await manager.send("call rehan")
        XCTAssertEqual(scripted.callCount, 0)
        XCTAssertEqual(opened.last?.url.absoluteString, "tel:03001234567")
        XCTAssertTrue(manager.activities.contains { $0.title.contains("(from memory)") })
    }

    func testCallUnknownNameReportsError() async {
        let (manager, scripted) = makeManager()
        manager.contactService = SpyContactService() // empty directory: contacts miss, memory miss
        await manager.send("call ghost")
        XCTAssertEqual(scripted.callCount, 0)
        XCTAssertTrue(manager.activities.contains { $0.title.contains("Couldn't find") })
    }

    func testShortNameSkipsMemoryLookup() async {
        let (manager, _) = makeManager()
        await manager.send("call me")
        // "me" is too short for substring memory search — honest service error.
        XCTAssertTrue(manager.activities.contains { $0.title == "Contacts unavailable on this build" })
    }

    func testMissingDigitsTurnAsksForNumber() async {
        let (manager, scripted) = makeManager()
        await manager.send("this is rehan's number remember it in memory")
        XCTAssertEqual(scripted.callCount, 0)
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("Rehan"))
    }
}
