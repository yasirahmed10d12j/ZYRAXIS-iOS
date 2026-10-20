import XCTest
@testable import ZYRAXIS

/// Romantic mode: secret trigger phrases, style injection, persistence.
/// Scripted AI doubles; no backend required.
@MainActor
final class RomanticModeTests: XCTestCase {

    private let router = FastCommandRouter()

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

    // MARK: - Router

    func testSecretPhrases() {
        XCTAssertEqual(router.route("kaccha papad"), .romanticMode(true))
        XCTAssertEqual(router.route("KACCHA PAPAD"), .romanticMode(true))
        XCTAssertEqual(router.route("pakka papad"), .romanticMode(false))
        // Common spellings/sayings and the explicit English forms.
        XCTAssertEqual(router.route("kacha papad"), .romanticMode(true))
        XCTAssertEqual(router.route("paka papad"), .romanticMode(false))
        XCTAssertEqual(router.route("romantic mode on"), .romanticMode(true))
        XCTAssertEqual(router.route("romantic mode off"), .romanticMode(false))
        XCTAssertEqual(router.route("kaccha papad chalu"), .romanticMode(true))
        XCTAssertEqual(router.route("pakka papad band"), .romanticMode(false))
        // Trailing punctuation is normalised away (we speak, Siri punctuates).
        XCTAssertEqual(router.route("kaccha papad!"), .romanticMode(true))
        XCTAssertEqual(router.route("Kaccha papad."), .romanticMode(true))
        // Near-misses must reach the AI, never toggle by accident.
        XCTAssertEqual(router.route("kaccha papad recipe"), .none)
        XCTAssertEqual(router.route("what is a kaccha papad"), .none)
        XCTAssertEqual(router.route("papad"), .none)
        XCTAssertEqual(router.route("kaccha"), .none)
        XCTAssertEqual(router.route("pakka"), .none)
    }

    // MARK: - Engine

    func testToggleOnConfirms() async {
        let (manager, scripted) = makeManager()
        await manager.send("kaccha papad")
        XCTAssertEqual(scripted.callCount, 0, "toggle must not call the AI service")
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("romantic mode ON"))
    }

    func testToggleOffConfirms() async {
        let (manager, scripted) = makeManager()
        await manager.send("kaccha papad")
        await manager.send("pakka papad")
        XCTAssertEqual(scripted.callCount, 0, "toggle must not call the AI service")
        let last = manager.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(last.contains("romantic mode OFF"))
    }

    /// The enriched style must actually reach the AI, and must carry the
    /// guardrails that keep it tasteful (no crude/possessive behaviour, and
    /// real questions still answered properly).
    func testRomanticSuffixCarriesStyleAndGuardrails() {
        let s = ConversationManager.romanticSuffix
        XCTAssertTrue(s.contains("romantic mode is ON"))
        XCTAssertTrue(s.contains("jaan"), "should invite pet names")
        XCTAssertTrue(s.lowercased().contains("never be crude"))
        XCTAssertTrue(s.lowercased().contains("never be possessive"))
        // Serious/factual questions must not be sacrificed for romance.
        XCTAssertTrue(s.lowercased().contains("answer it properly"))
    }

    func testStyleInjectedOnlyWhenOn() async {
        let (manager, scripted) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "hi", requestId: id))]
        }
        await manager.send("hello")
        let plain = scripted.lastRequest?.context.systemPrompt ?? ""
        XCTAssertFalse(plain.contains("romantic mode is ON"))
        await manager.send("kaccha papad")
        await manager.send("hello again")
        let styled = scripted.lastRequest?.context.systemPrompt ?? ""
        XCTAssertTrue(styled.contains("romantic mode is ON"))
        await manager.send("pakka papad")
        await manager.send("hello once more")
        let clean = scripted.lastRequest?.context.systemPrompt ?? ""
        XCTAssertFalse(clean.contains("romantic mode is ON"))
    }

    func testRomanticModePersists() {
        let defaults = UserDefaults(suiteName: "zyraxis.romantic.tests")!
        defaults.removePersistentDomain(forName: "zyraxis.romantic.tests")
        SettingsStore(defaults: defaults).romanticMode = true
        XCTAssertTrue(SettingsStore(defaults: defaults).romanticMode)
        var fresh = SettingsStore(defaults: defaults)
        fresh.resetToDefaults()
        XCTAssertFalse(fresh.romanticMode)
    }
}
