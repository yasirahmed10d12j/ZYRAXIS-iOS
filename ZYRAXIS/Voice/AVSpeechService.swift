import Foundation
import AVFoundation

/// Real text-to-speech behind `SpeechService`, using AVSpeechSynthesizer.
///
/// - `speak()` stops any ongoing utterance first (no duplicate/overlapping
///   speech), then speaks with the system default voice and rate.
/// - `stop()` is immediate; `pause()`/`resume()` map to the synthesizer's
///   boundary-immediate controls.
/// - Speaking state is the synthesizer's own `isSpeaking` (real, not cached).
/// - Completion is detected by a short-lived watchdog task (200 ms polls,
///   alive only while speaking) — no delegate object, no isolation tricks,
///   no leaked synthesizers (one instance for the app lifetime).
/// - Callers (ConversationManager) stop speech on cancel/new requests, so a
///   cancelled request is never spoken after the fact.
///
/// UNVERIFIED — REQUIRES XCODE/DEVICE: never run (no Xcode/audio here).
@MainActor
public final class AVSpeechService: NSObject, SpeechService {

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    private let synthesizer = AVSpeechSynthesizer()
    private var watchdog: Task<Void, Never>?

    public override init() {
        super.init()
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopImmediately()
        let utterance = AVSpeechUtterance(string: trimmed)
        // System default voice + rate: respects the user's language/settings.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
        startWatchdog()
        ZyraxisLogger.log(.voice, "TTS started (\(trimmed.count) chars)")
    }

    public func stop() async {
        stopImmediately()
    }

    public func pause() async {
        _ = synthesizer.pauseSpeaking(at: .immediate)
    }

    public func resume() async {
        _ = synthesizer.continueSpeaking()
    }

    // MARK: - Private

    private func stopImmediately() {
        watchdog?.cancel()
        watchdog = nil
        if synthesizer.isSpeaking {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Bounded completion detector: polls only while speech is active,
    /// logs the real finish, then ends. Cancelled by stop()/speak().
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while let strongSelf = self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                if !strongSelf.synthesizer.isSpeaking {
                    ZyraxisLogger.log(.voice, "TTS finished")
                    return
                }
            }
        }
    }
}
