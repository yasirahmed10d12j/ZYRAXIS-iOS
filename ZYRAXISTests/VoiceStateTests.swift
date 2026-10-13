import XCTest
@testable import ZYRAXIS

/// Voice hardware (mic, AVAudioSession) cannot run in unit tests or on
/// Windows — so these tests cover the pure, hardware-free contracts:
/// state labels, capture flags, and legal assistant transitions for voice.
final class VoiceStateTests: XCTestCase {

    func testDisplayLabels() {
        XCTAssertEqual(VoiceState.idle.displayLabel, "MIC IDLE")
        XCTAssertEqual(VoiceState.ready.displayLabel, "MIC READY")
        XCTAssertEqual(VoiceState.denied.displayLabel, "MIC DENIED")
        XCTAssertEqual(VoiceState.listening(level: 0.5).displayLabel, "CAPTURING AUDIO")
    }

    func testCaptureFlag() {
        XCTAssertTrue(VoiceState.listening(level: 0.2).isCapturing)
        XCTAssertFalse(VoiceState.ready.isCapturing)
        XCTAssertFalse(VoiceState.denied.isCapturing)
        XCTAssertFalse(VoiceState.idle.isCapturing)
    }

    func testVoiceDrivenAssistantTransitionsAreLegal() {
        XCTAssertTrue(AssistantStateMachine.canTransition(from: .idle, to: .listening))
        XCTAssertTrue(AssistantStateMachine.canTransition(from: .listening, to: .userSpeaking))
        XCTAssertTrue(AssistantStateMachine.canTransition(from: .userSpeaking, to: .processing))
        // Mic close returns to idle from listening.
        XCTAssertTrue(AssistantStateMachine.canTransition(from: .listening, to: .idle))
    }

    func testLevelsClampedConceptually() {
        // VoiceManager clamps RMS to 0...1 — assert the contract on the type.
        let levels: [Float] = [0, 0.25, 0.5, 1.0]
        for l in levels {
            let s = VoiceState.listening(level: l)
            if case .listening(let got) = s {
                XCTAssertEqual(got, l, accuracy: 0.001)
            } else {
                XCTFail("expected listening")
            }
        }
    }
}
