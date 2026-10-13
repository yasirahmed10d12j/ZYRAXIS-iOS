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
