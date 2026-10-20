import XCTest
import AVFoundation
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
    func testRomanticSuffixCarriesPersonaAndGuardrails() {
        let s = ConversationManager.romanticSuffix
        XCTAssertTrue(s.contains("romantic mode is ON"))
        // Feminine, Hinglish persona.
        XCTAssertTrue(s.lowercased().contains("girlfriend mode"))
        XCTAssertTrue(s.lowercased().contains("hinglish"))
        XCTAssertTrue(s.contains("jaan"), "should invite pet names")
        // Wit / double meaning must be understood, not dodged.
        XCTAssertTrue(s.lowercased().contains("double meaning"))
        XCTAssertTrue(s.lowercased().contains("emoji"))
        // Must never break character with an error or refusal.
        XCTAssertTrue(s.lowercased().contains("never output an error"))
        XCTAssertTrue(s.lowercased().contains("stay in character"))
        // Guardrails stay.
        XCTAssertTrue(s.lowercased().contains("never crude"))
        XCTAssertTrue(s.lowercased().contains("never possessive"))
        // Real questions are still answered correctly.
        XCTAssertTrue(s.lowercased().contains("answer it"))
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
        let fresh = SettingsStore(defaults: defaults)
        fresh.resetToDefaults()
        XCTAssertFalse(fresh.romanticMode)
    }

    // MARK: - Graceful failure (no cold error in Companion Mode)

    /// A provider error must not yank the user out of the persona with a
    /// technical message; it is said warmly instead. The honest signal (a
    /// system activity) still exists for debugging.
    func testRomanticModeShowsWarmFailureNotColdError() async {
        let (manager, scripted) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "hi", requestId: id))]
        }
        await manager.send("kaccha papad")
        scripted.failWith = NetworkError.timeout
        await manager.send("kuch batao")

        let systemMessages = manager.messages.filter { $0.role == .system }.map(\.text)
        XCTAssertFalse(
            systemMessages.contains { $0.lowercased().contains("timed out") },
            "cold technical error must not be shown in Companion Mode"
        )
        XCTAssertTrue(
            systemMessages.contains { $0.lowercased().contains("jaan") || $0.contains("🥺") },
            "failure should be spoken warmly, in character"
        )
    }

    /// The same failure WITHOUT Companion Mode keeps the normal honest error,
    /// proving the warm message is specific to the mode.
    func testNonRomanticModeKeepsTechnicalError() async {
        let (manager, scripted) = makeManager { id in
            [.completed(requestId: id, response: AIResponse(text: "hi", requestId: id))]
        }
        scripted.failWith = NetworkError.timeout
        await manager.send("kuch batao")
        let systemMessages = manager.messages.filter { $0.role == .system }.map(\.text)
        XCTAssertTrue(
            systemMessages.contains { $0.lowercased().contains("timed out") },
            "outside Companion Mode the honest error must remain"
        )
    }

    // MARK: - Female voice preference

    /// Companion Mode asks the TTS layer for a female voice; the detection
    /// helper must recognise Apple's common female voice names.
    func testFemaleVoiceDetection() {
        let voices = AVSpeechService.allVoices()
        // On a simulator/CI runner the voice list can be empty — only assert
        // the classifier's own logic in that case.
        guard !voices.isEmpty else { return }
        let detected = voices.filter(AVSpeechService.isFemaleVoice)
        XCTAssertFalse(detected.isEmpty, "expected at least one female voice to be recognised")
    }

    /// With no explicit user voice, Companion Mode must pick a female voice
    /// for Hinglish text when one exists for the language.
    func testCompanionModePicksFemaleVoiceForHinglish() {
        let hinglish = "arre yaar, kaisi ho? aaj bahut maza aaya"
        let female = AVSpeechService.voiceIdentifierForText(hinglish, preferFemale: true)
        let neutral = AVSpeechService.voiceIdentifierForText(hinglish)
        // An explicit user choice always wins.
        let pinned = AVSpeechService.voiceIdentifierForText(
            hinglish, preferred: "com.example.voice", preferFemale: true
        )
        XCTAssertEqual(pinned, "com.example.voice")
        // Both auto paths must resolve to *some* voice when the system has any.
        if !AVSpeechService.allVoices().isEmpty {
            XCTAssertNotNil(neutral)
        }
        if let female {
            let voice = AVSpeechSynthesisVoice(identifier: female)
            XCTAssertNotNil(voice)
            XCTAssertTrue(AVSpeechService.isFemaleVoice(voice!))
        }
    }
}
