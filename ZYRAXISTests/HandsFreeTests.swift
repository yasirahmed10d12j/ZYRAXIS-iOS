import XCTest
@testable import ZYRAXIS

/// Hands-free loop repairs: adaptive noise floor, throttled level UI,
/// re-listen after in-app fast turns (and never after app-opening turns).
/// No backend, no device required.
@MainActor
final class HandsFreeTests: XCTestCase {

    private func makeManager(
        builder: @escaping (UUID) -> [AIStreamEvent] = { _ in [] }
    ) -> (ConversationManager, ScriptedAIService, SettingsStore) {
        let sm = AssistantStateMachine()
        let settings = SettingsStore()
        settings.selectedProvider = .mock
        settings.handsFreeMode = true
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
        return (manager, scripted, settings)
    }

    // MARK: - Adaptive noise floor

    func testAdaptiveThresholdRisesInNoise() {
        var detector = SilenceDetector()
        let start = Date()
        detector.reset(at: start)
        // Noisy room hum for a second — floor learns 0.05.
        for i in 0..<10 {
            XCTAssertNil(detector.ingest(level: 0.05, at: start.addingTimeInterval(Double(i) * 0.1)))
        }
        XCTAssertEqual(detector.currentNoiseFloor, 0.05, accuracy: 0.001)
        XCTAssertGreaterThan(detector.effectiveThreshold, 0.15)
        // Loud-enough speech still arms it…
        XCTAssertNil(detector.ingest(level: 0.3, at: start.addingTimeInterval(1.0)))
        // …and room-level quiet afterwards still ends the utterance.
        XCTAssertNil(detector.ingest(level: 0.05, at: start.addingTimeInterval(1.1)))
        XCTAssertEqual(
            detector.ingest(level: 0.05, at: start.addingTimeInterval(2.4)),
            .utteranceEnded
        )
    }

    func testNoiseFloorResets() {
        var detector = SilenceDetector()
        let start = Date()
        detector.reset(at: start)
        _ = detector.ingest(level: 0.2, at: start.addingTimeInterval(0.1))
        XCTAssertGreaterThan(detector.currentNoiseFloor, 0)
        detector.reset(at: start.addingTimeInterval(1))
        XCTAssertEqual(detector.currentNoiseFloor, 0)
        XCTAssertEqual(detector.effectiveThreshold, detector.silenceThreshold)
    }

    // MARK: - Level UI throttle (audio path untouched)

    func testEmitLevelThrottlesTinyMoves() {
        let manager = VoiceManagerImpl()
        let t0 = Date()
        manager.emitLevel(0.5, at: t0)
        guard case .listening(let first) = manager.voiceState else {
            return XCTFail("expected listening")
        }
        XCTAssertEqual(first, 0.5, accuracy: 0.001)
        // 0.01 move within 50ms — suppressed, no re-publish.
        manager.emitLevel(0.51, at: t0.addingTimeInterval(0.05))
        guard case .listening(let held) = manager.voiceState else {
            return XCTFail("expected listening")
        }
        XCTAssertEqual(held, 0.5, accuracy: 0.001)
        // Real move passes immediately.
        manager.emitLevel(0.9, at: t0.addingTimeInterval(0.06))
        guard case .listening(let moved) = manager.voiceState else {
            return XCTFail("expected listening")
        }
        XCTAssertEqual(moved, 0.9, accuracy: 0.001)
    }

    // MARK: - Re-listen coverage

    func testVoiceFastAnswerRelistens() async {
        let (manager, scripted, _) = makeManager()
        var relistens = 0
        manager.autoListenHandler = { relistens += 1 }
        await manager.acceptExternalTranscript("what time is it", isFinal: true)
        XCTAssertEqual(scripted.callCount, 0, "fast answer must not call the AI service")
        XCTAssertEqual(relistens, 1, "in-app fast turn must re-arm hands-free")
    }

    func testVoiceReminderRelistensEvenOnFailure() async {
        let (manager, _, _) = makeManager()
        manager.taskService = SpyTaskService() // create() refuses — loop must survive anyway
        var relistens = 0
        manager.autoListenHandler = { relistens += 1 }
        await manager.acceptExternalTranscript("remind me to stretch in 5 minutes", isFinal: true)        XCTAssertEqual(relistens, 1)
        XCTAssertTrue(manager.activities.contains { $0.title.contains("Couldn't create reminder") })
    }

    func testAppOpeningTurnDoesNotRelisten() async {
        let (manager, _, _) = makeManager()
        var opened: [OpenRequest] = []
        manager.openURLHandler = { opened.append($0) }
        var relistens = 0
        manager.autoListenHandler = { relistens += 1 }
        await manager.acceptExternalTranscript("open youtube", isFinal: true)
        XCTAssertEqual(opened.count, 1, "command must still execute")
        XCTAssertEqual(relistens, 0, "external-app turns background us — mic cannot survive there")
    }
}
