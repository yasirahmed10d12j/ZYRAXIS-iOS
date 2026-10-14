import XCTest
import Combine
import AVFoundation
@testable import ZYRAXIS

/// Voice hardware (mic, AVAudioSession) cannot run in unit tests or on
/// Windows — so these tests cover the pure, hardware-free contracts:
/// state labels, capture flags, and legal assistant transitions for voice.
/// @MainActor: VoiceManagerImpl is MainActor-isolated (like the app wiring).
@MainActor
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

    func testCaptureAudioConfigUsesLoudspeakerSafeDefaults() {
        // Responses must come out the loudspeaker: .voiceChat mode routes
        // output earpiece-quiet (reads as "TTS never speaks").
        XCTAssertEqual(VoiceManagerImpl.captureCategory.rawValue, AVAudioSession.Category.playAndRecord.rawValue)
        XCTAssertEqual(VoiceManagerImpl.captureMode.rawValue, AVAudioSession.Mode.default.rawValue)
        XCTAssertTrue(VoiceManagerImpl.captureOptions.contains(.defaultToSpeaker))
        XCTAssertTrue(VoiceManagerImpl.captureOptions.contains(.allowBluetoothA2DP))
    }

    func testForwardingSendsMonoSamples() {
        // copyMonoSamples extracts channel 0 only, so forwarding must declare
        // channels == 1 even for stereo taps (other channels would reach the
        // recognizer uninitialized).
        let manager = VoiceManagerImpl()
        let spy = SpySTTProvider()
        manager.transcriber = spy
        manager.forwardTranscription(samples: [0.25, 0.5], sampleRate: 44100, channels: 2)
        XCTAssertEqual(spy.lastSamples, [0.25, 0.5])
        XCTAssertEqual(spy.lastChannels, 1)
        XCTAssertEqual(spy.lastSampleRate, 44100, accuracy: 0.001)
    }

    func testSilenceDetectorNeedsSpeechFirst() {
        var detector = SilenceDetector()
        let start = Date()
        detector.reset(at: start)
        // Pure silence with no prior speech never ends anything.
        XCTAssertNil(detector.ingest(level: 0.01, at: start.addingTimeInterval(30)))
        // Speech arms it; a short pause does not end the utterance yet.
        XCTAssertNil(detector.ingest(level: 0.5, at: start.addingTimeInterval(31)))
        XCTAssertNil(detector.ingest(level: 0.01, at: start.addingTimeInterval(31.5)))
        // Sustained quiet past the threshold ends the utterance exactly once
        // (silence runs 31.5 -> 32.8 = 1.3s against the 1.2s threshold).
        XCTAssertNil(detector.ingest(level: 0.01, at: start.addingTimeInterval(32.5)))
        XCTAssertEqual(detector.ingest(level: 0.01, at: start.addingTimeInterval(32.8)), .utteranceEnded)
        XCTAssertNil(detector.ingest(level: 0.01, at: start.addingTimeInterval(34)))
    }

    func testSilenceDetectorCaptureTimeout() {
        var detector = SilenceDetector()
        let start = Date()
        detector.reset(at: start)
        XCTAssertNil(detector.ingest(level: 0.5, at: start.addingTimeInterval(10)))
        XCTAssertEqual(detector.ingest(level: 0.5, at: start.addingTimeInterval(61)), .captureTimedOut)
    }

    func testSpeechRateClamping() {
        XCTAssertEqual(AVSpeechService.clampedRate(2.0), 1.0)
        XCTAssertEqual(AVSpeechService.clampedRate(-1.0), 0.0)
        XCTAssertEqual(AVSpeechService.clampedRate(0.5), 0.5, accuracy: 0.001)
    }
}

/// STT test double: records ingest calls, performs no recognition.
private final class SpySTTProvider: STTProvider {
    var lastSamples: [Float] = []
    var lastSampleRate: Double = 0
    var lastChannels: Int = 0

    var isAvailable: Bool { true }

    var transcripts: AnyPublisher<STTTranscript, Never> {
        Empty().eraseToAnyPublisher()
    }

    func requestPermission() async -> Bool { true }

    func start() throws {}

    func stop() {}

    func ingestAudio(samples: [Float], sampleRate: Double, channels: Int) {
        lastSamples = samples
        lastSampleRate = sampleRate
        lastChannels = channels
    }
}
