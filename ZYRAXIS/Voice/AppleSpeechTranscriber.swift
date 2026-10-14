import Foundation
import Combine
import AVFoundation
import Speech

/// Real speech-to-text behind `STTProvider`, using Apple's Speech framework.
///
/// - Audio arrives via `ingestAudio(samples:sampleRate:channels:)` as copied
///   mono floats (Sendable values — the mic tap never shares buffers across
///   isolation domains). Buffers are reconstructed and appended to a live
///   `SFSpeechAudioBufferRecognitionRequest`.
/// - Partials stream as `STTTranscript(isFinal: false)`; finals as `true`.
/// - Nothing is ever fabricated: silence produces nothing, errors produce
///   nothing (logged), and `isAvailable` reflects the real recognizer state.
/// - Server-based recognition by default (network); on-device mode is a
///   future opt-in, not claimed here.
/// - `stop()` ends audio gracefully so the trailing final still arrives
///   (mic-toggle-off = utterance boundary). Resources (request/task) are
///   released when the task ends.
///
/// UNVERIFIED — REQUIRES XCODE/DEVICE: compiles against Apple SDKs only;
/// never run (no Xcode, no microphone in this environment).
@MainActor
public final class AppleSpeechTranscriber: ObservableObject, STTProvider {

    public var isAvailable: Bool {
        makeRecognizer()?.isAvailable ?? false
    }

    public var transcripts: AnyPublisher<STTTranscript, Never> {
        subject.eraseToAnyPublisher()
    }

    private let subject = PassthroughSubject<STTTranscript, Never>()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var cachedFormat: AVAudioFormat?
    private var speechAuthorized = false
    /// BCP-47 locale for the recognizer, or nil for system default.
    /// Applied at the next `start()` (a live task keeps its locale).
    public var localeIdentifier: String?

    public init() {}
    // MARK: - Permission

    public func requestPermission() async -> Bool {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        speechAuthorized = (status == .authorized)
        ZyraxisLogger.log(.voice, "speech authorization: \(String(describing: status))")
        return speechAuthorized
    }

    // MARK: - Lifecycle

    public func applyLocale(identifier: String?) {
        localeIdentifier = identifier
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        if let id = localeIdentifier, !id.isEmpty {
            return SFSpeechRecognizer(locale: Locale(identifier: id))
        }
        return SFSpeechRecognizer()
    }

    public func start() throws {
        guard let recognizer = makeRecognizer(), recognizer.isAvailable else {
            throw AppError.voice("Speech recognition is unavailable on this device or locale.")
        }
        guard speechAuthorized else {
            throw AppError.voice("Speech recognition permission required. Enable it in iOS Settings.")
        }
        stop() // clean slate: never two live tasks
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // NOTE: server-based recognition (default). requiresOnDeviceRecognition
        // stays false — on-device mode needs a downloaded model per locale.
        activeRequest = request
        cachedFormat = nil
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Extract Sendable values synchronously: result/error are
            // non-Sendable and must not cross into the hop below.
            let text = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handleResult(text: text, isFinal: isFinal, failed: failed, message: message)
            }
        }
        ZyraxisLogger.log(.voice, "STT started")
    }

    public func stop() {
        // Graceful end: the recognizer still delivers the trailing final,
        // which the handler forwards before releasing resources.
        activeRequest?.endAudio()
        activeRequest = nil
        cachedFormat = nil
    }

    public func forceCancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        activeRequest = nil
        cachedFormat = nil
    }

    // MARK: - Audio ingest (called on MainActor by VoiceManager)

    public func ingestAudio(samples: [Float], sampleRate: Double, channels: Int) {
        guard !samples.isEmpty, let request = activeRequest else { return }
        let format: AVAudioFormat
        if let cached = cachedFormat,
           cached.sampleRate == sampleRate,
           cached.channelCount == AVAudioChannelCount(channels) {
            format = cached
        } else {
            guard channels > 0,
                  let fresh = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: false
                  ) else { return }
            cachedFormat = fresh
            format = fresh
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress,
                  let dst = buffer.floatChannelData?.pointee else { return }
            dst.assign(from: base, count: samples.count)
        }
        request.append(buffer)
    }

    // MARK: - Private

    private func handleResult(text: String, isFinal: Bool, failed: Bool, message: String?) {
        if failed {
            ZyraxisLogger.error(.voice, "STT error: \(message ?? "unknown")")
            recognitionTask = nil
            activeRequest = nil
            return
        }
        guard !text.isEmpty else { return }
        subject.send(STTTranscript(text: text, isFinal: isFinal))
        if isFinal {
            recognitionTask = nil
            activeRequest = nil
            ZyraxisLogger.log(.voice, "STT final received (\(text.count) chars)")
        }
    }
}
