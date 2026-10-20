import Foundation

/// Future streaming-TTS architecture. Phase 4 ships a real AVSpeechSynthesizer
/// implementation (`AVSpeechService`) behind this protocol:
///
/// completed/streamed text → SpeechService.speak() → audio out.
///
/// Concurrency note: intentionally NOT `Sendable`-constrained — real providers
/// own non-Sendable synthesizers on `MainActor`. Value types stay `Sendable`.
/// `NoOpSpeechService` remains for tests and the text-only path.
public protocol SpeechService {
    var isSpeaking: Bool { get }
    func speak(_ text: String) async
    func stop() async
    func pause() async
    func resume() async
    /// Applies voice + rate for subsequent utterances (called before each
    /// `speak` by the engine).
    func applyVoiceSettings(rate: Float, voiceIdentifier: String?, preferFemale: Bool)
}

public extension SpeechService {
    /// Default: voice selection unsupported (honest no-op).
    func applyVoiceSettings(rate: Float, voiceIdentifier: String?, preferFemale: Bool) {}

    /// Convenience for callers that do not care about gender (kept so the
    /// older two-argument call sites and test doubles keep working).
    func applyVoiceSettings(rate: Float, voiceIdentifier: String?) {
        applyVoiceSettings(rate: rate, voiceIdentifier: voiceIdentifier, preferFemale: false)
    }
}

/// Honest placeholder: every method is a no-op. Exists so the
/// ConversationManager hook compiles and tests can inject a spy.
public struct NoOpSpeechService: SpeechService, Sendable {

    public var isSpeaking: Bool { false }

    public init() {}

    public func speak(_ text: String) async {}
    public func stop() async {}
    public func pause() async {}
    public func resume() async {}
}
