import Foundation
import Combine

/// Future speech-to-text provider. Phase 4 ships a real Apple Speech
/// implementation (`AppleSpeechTranscriber`) behind this seam:
///
/// microphone (VoiceManager, real)
///   ↓ mono float samples (copied in the audio tap — Sendable, no shared buffers)
/// STTProvider.ingestAudio (AppleSpeechTranscriber, real)
///   ↓ text (partials + finals, never fabricated)
/// ConversationManager.acceptExternalTranscript(_:isFinal:)
///   ↓
/// AIService streaming response
///
/// Concurrency note: the protocol is intentionally NOT `Sendable`-constrained.
/// Real providers are `@MainActor`-bound (they own recognition tasks and
/// publishers); value-type providers stay `Sendable`. Mirrors `AIService`.
public protocol STTProvider {
    /// False until a real implementation is started and available.
    var isAvailable: Bool { get }
    /// Partial transcripts (false) and finals (true).
    var transcripts: AnyPublisher<STTTranscript, Never> { get }

    func requestPermission() async -> Bool
    func start() throws
    func stop()
    /// Feeds mic audio. Mono float samples + format facts only — plain
    /// Sendable values, so the audio tap never shares buffers across
    /// isolation domains. Ignored unless `start()` was called.
    func ingestAudio(samples: [Float], sampleRate: Double, channels: Int)
}

public extension STTProvider {
    func ingestAudio(samples: [Float], sampleRate: Double, channels: Int) {}
}

public struct STTTranscript: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Phase 2/4 placeholder: honestly unavailable. Lets call sites compile and
/// Settings show STT status without implying recognition works.
/// `ingestAudio` is the protocol-extension no-op.
public struct UnimplementedSTTProvider: STTProvider, Sendable {

    public var isAvailable: Bool { false }

    public var transcripts: AnyPublisher<STTTranscript, Never> {
        Empty().eraseToAnyPublisher()
    }

    public init() {}

    public func requestPermission() async -> Bool { false }

    public func start() throws {
        throw AppError.voice("Speech recognition is not implemented yet.")
    }

    public func stop() {}
}
