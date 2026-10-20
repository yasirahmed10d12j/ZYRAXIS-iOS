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
public final class AVSpeechService: NSObject, @preconcurrency SpeechService {

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    private let synthesizer = AVSpeechSynthesizer()
    private var watchdog: Task<Void, Never>?

    /// Speaking rate 0.0...1.0 (system default 0.5). Applied per utterance.
    public var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Explicit voice identifier, or nil for the system default voice.
    public var voiceIdentifier: String?
    /// Companion Mode: prefer a female voice for auto-detected languages so
    /// Hinglish/Hindi lines are not read in a male voice.
    public var preferFemaleVoice = false

    public override init() {
        super.init()
    }

    /// Applies engine-synced voice settings (clamped to the valid range).
    public func applyVoiceSettings(rate: Float, voiceIdentifier: String?, preferFemale: Bool) {
        speechRate = Self.clampedRate(rate)
        self.voiceIdentifier = voiceIdentifier
        self.preferFemaleVoice = preferFemale
    }

    /// Valid speech rates for Settings sliders/tests.
    public static func clampedRate(_ rate: Float) -> Float {
        min(1.0, max(0.0, rate))
    }

    /// Returns high-quality voices for the current locale, prioritizing
    /// "Enhanced" and "Premium" voices that sound more natural.
    /// Falls back to all available voices if none are marked enhanced.
    public static func recommendedVoices(for locale: Locale = .current) -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let forLocale = all.filter { $0.language.hasPrefix(locale.identifier.prefix(2)) || $0.language == locale.identifier }
        // Enhanced voices (downloadable, higher quality) have identifiers containing "enhanced" or are marked as such
        let enhanced = forLocale.filter { $0.identifier.contains("enhanced") || $0.quality == .enhanced }
        if !enhanced.isEmpty { return enhanced }
        // Fallback: premium/default voices for the locale
        return forLocale.isEmpty ? all : forLocale
    }

    /// All available voices (for Settings picker).
    public static func allVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
    }

    /// Detects the dominant script of the text and returns a matching voice
    /// identifier, or nil if no match (falls back to explicit/default).
    /// Supports: Devanagari (Hindi/Marathi), Arabic/Urdu, Latin (English/etc).
    ///
    /// `preferFemale` is used by Companion Mode: among the matching voices it
    /// picks a female one, so Hinglish lines are not read in a male voice.
    public static func voiceIdentifierForText(
        _ text: String,
        preferred: String? = nil,
        preferFemale: Bool = false
    ) -> String? {
        // If user explicitly set a voice, respect it
        if let preferred, !preferred.isEmpty {
            return preferred
        }
        let script = dominantScript(of: text)
        let all = AVSpeechSynthesisVoice.speechVoices()
        let candidates = all.filter { $0.language.hasPrefix(script.localePrefix) }
        let pool = candidates.isEmpty ? all : candidates
        // Prefer enhanced, then gender, then any.
        let enhanced = pool.filter { $0.quality == .enhanced }
        let base = enhanced.isEmpty ? pool : enhanced
        if preferFemale {
            let female = base.filter(Self.isFemaleVoice)
            if let f = female.first { return f.identifier }
            // No female in the enhanced set — look across the whole locale.
            let femaleAny = pool.filter(Self.isFemaleVoice)
            if let f = femaleAny.first { return f.identifier }
        }
        return base.first?.identifier
    }

    /// Best-effort female detection. iOS exposes no gender API, so we rely on
    /// the well-known voice names Apple ships (Samantha, Lekha, Siri female
    /// names, etc.). Unknown names are treated as not-female, which only means
    /// the picker falls through to the default — never a crash.
    public static func isFemaleVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let name = voice.name.lowercased()
        let femaleNames = [
            "samantha", "karen", "moira", "tessa", "fiona", "victoria",
            "lekha", "veena", "rishi_f", "amelie", "anna", "ellen",
            "ioana", "laura", "melina", "yelda", "zosia", "sara",
            "alice", "amelie", "audrey", "marie", "nora", "paulina",
            "milena", "kanya", "damayanti", "sira", "female"
        ]
        return femaleNames.contains { name.contains($0) }
    }

    private static func dominantScript(of text: String) -> Script {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            let script = Script.of(scalar)
            if script != Script.unknown {
                counts[script, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? Script.latin
    }

    private enum Script {
        case devanagari // Hindi, Marathi, Sanskrit
        case arabic     // Arabic, Urdu, Persian
        case latin      // English, European languages
        case unknown

        var localePrefix: String {
            switch self {
            case .devanagari: return "hi" // Hindi
            case .arabic: return "ur"     // Urdu (Pakistan)
            case .latin: return "en"      // English default
            case .unknown: return "en"
            }
        }

        static func of(_ scalar: UnicodeScalar) -> Script {
            let value = scalar.value
            switch value {
            case 0x0900...0x097F: return .devanagari
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
            case 0x0000...0x024F: return .latin // Basic Latin + Latin Extended-A/B
            default: return .unknown
            }
        }
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopImmediately()
        let utterance = AVSpeechUtterance(string: trimmed)
        // Explicit voice when set and valid; otherwise auto-detect from text
        // language (Companion Mode additionally prefers a female voice).
        let voiceId = voiceIdentifier ?? Self.voiceIdentifierForText(
            trimmed,
            preferFemale: preferFemaleVoice
        )
        if let id = voiceId,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        utterance.rate = speechRate
        // Slightly higher pitch in Companion Mode for a softer, female tone
        // (still within the natural range — never cartoonish).
        utterance.pitchMultiplier = preferFemaleVoice ? 1.08 : 1.0
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
