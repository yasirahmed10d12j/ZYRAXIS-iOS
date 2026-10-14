import Foundation
import AVFoundation
import Combine

/// Voice capture abstraction.
///
/// Real, verified-by-design (UNVERIFIED — REQUIRES XCODE/DEVICE to run):
/// - microphone permission + audio session configuration
/// - start/stop capture with live mic LEVEL metering
/// - audio interruption handling
/// - optional live transcription via attached `STTProvider`
///   (copied samples, no shared buffers; finals route to the engine)
///
/// Nothing is faked: `startListening()` opens the mic and publishes levels,
/// but never fabricates transcripts.
public protocol VoiceManager: AnyObject {
    var voiceState: VoiceState { get }
    var voiceStatePublisher: AnyPublisher<VoiceState, Never> { get }

    func requestPermission() async -> Bool
    func configureAudioSession() throws
    func startListening() throws
    func stopListening()
}

/// Silence-based utterance boundary for hands-free use. Pure value type —
/// fully unit-testable with explicit timestamps, no audio needed.
///
/// Policy: never end on pure silence (the mic may simply not have heard
/// anything yet). Once speech crosses the threshold, sustained silence ends
/// the utterance; an absolute capture cap always ends it. The manager stops
/// the mic on either event, which ends STT gracefully so the trailing final
/// still arrives and auto-sends — no second tap required.
public struct SilenceDetector: Equatable, Sendable {

    public enum Event: Equatable, Sendable {
        case utteranceEnded
        case captureTimedOut
    }

    /// RMS level at/above which audio counts as speech.
    public var silenceThreshold: Float = 0.08
    /// Quiet seconds after speech before the utterance ends.
    public var silenceSeconds: TimeInterval = 1.2
    /// Absolute capture cap from mic-open (safety, speech or not).
    public var maxCaptureSeconds: TimeInterval = 60

    private var startedAt: Date?
    private var heardSpeech = false
    private var silenceStart: Date?

    public init() {}

    public mutating func reset(at date: Date = Date()) {
        startedAt = date
        heardSpeech = false
        silenceStart = nil
    }

    /// Feed one metered level. Returns an event at most once per boundary
    /// (callers stop capture on it, then reset on next mic open).
    public mutating func ingest(level: Float, at date: Date = Date()) -> Event? {
        guard let start = startedAt else {
            reset(at: date)
            return nil
        }
        if date.timeIntervalSince(start) >= maxCaptureSeconds {
            return .captureTimedOut
        }
        if level >= silenceThreshold {
            heardSpeech = true
            silenceStart = nil
            return nil
        }
        guard heardSpeech else { return nil }
        if let quietSince = silenceStart {
            if date.timeIntervalSince(quietSince) >= silenceSeconds {
                silenceStart = nil
                return .utteranceEnded
            }
            return nil
        }
        silenceStart = date
        return nil
    }
}

@MainActor
public final class VoiceManagerImpl: ObservableObject, @preconcurrency VoiceManager {

    @Published public private(set) var state: VoiceState = .idle

    public var voiceState: VoiceState { state }
    public var voiceStatePublisher: AnyPublisher<VoiceState, Never> {
        $state.eraseToAnyPublisher()
    }

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var interruptionObserver: NSObjectProtocol?

    /// Optional live transcriber. When set, the audio tap forwards copied
    /// mono samples alongside level metering — one tap, two consumers, no
    /// fabricated audio. Nil = level metering only.
    public var transcriber: (any STTProvider)?

    /// Hands-free auto-stop: when true (and a transcriber is attached), the
    /// mic closes itself after an utterance ends or the capture cap hits —
    /// the trailing STT final then auto-sends. Set from Settings' hands-free
    /// toggle whenever the mic opens. False = manual close only.
    public var autoStopOnSilence = false

    /// Hands-free setup in one call: silence threshold comes from Settings.
    public func configureHandsFree(enabled: Bool, silenceSeconds: Double) {
        autoStopOnSilence = enabled
        silenceDetector.silenceSeconds = min(3.0, max(0.6, silenceSeconds))
    }
    private var silenceDetector = SilenceDetector()

    public init() {
        observeInterruptions()
        // NOTE: interruption observer lives for the app lifetime (VoiceManager
        // is owned by AppDependencies for the whole process), so no removal.
        // This also avoids MainActor-isolated deinit issues under Swift 6.
    }

    // MARK: - Permission

    public func requestPermission() async -> Bool {
        state = .requestingPermission
        let granted = await withCheckedContinuation { cont in
            session.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        state = granted ? .ready : .denied
        return granted
    }

    // MARK: - Session + capture

    /// Single shared audio configuration for BOTH mic capture and spoken
    /// responses. The mic needs play-and-record; responses must come out the
    /// LOUDSPEAKER (`.voiceChat` mode routes output earpiece-quiet, which
    /// reads as "TTS never speaks"). Bluetooth stays available for headsets.
    /// Known limitation: speaker bleed into a hot mic can self-transcribe
    /// (no echo gate) — stopping the mic before long replies avoids it.
    static let captureCategory: AVAudioSession.Category = .playAndRecord
    static let captureMode: AVAudioSession.Mode = .default
    static let captureOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]

    public func configureAudioSession() throws {
        do {
            try session.setCategory(Self.captureCategory, mode: Self.captureMode, options: Self.captureOptions)
            try session.setActive(true, options: [])
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func startListening() throws {
        // Ensure permission first.
        if session.recordPermission != .granted {
            state = .denied
            throw AppError.voice("Microphone permission not granted.")
        }
        try configureAudioSession()

        stopEngineSilently()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Tap measures REAL input RMS for the core animation and, when a
        // transcriber is attached, forwards COPIED mono samples for STT.
        // No recognition is performed here.
        // NOTE: weak self — the tap closure must not retain the manager, and
        // @Sendable task closures may only capture Sendable values strongly.
        // The buffer itself never crosses isolation: level + samples + format
        // facts are extracted synchronously on the audio thread.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.rmsLevel(of: buffer)
            let samples = Self.copyMonoSamples(of: buffer)
            let sampleRate = buffer.format.sampleRate
            let channels = Int(buffer.format.channelCount)
            Task { @MainActor [weak self] in
                self?.state = .listening(level: level)
                self?.forwardTranscription(samples: samples, sampleRate: sampleRate, channels: channels)
                self?.ingestLevelForAutoStop(level: level)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed(error.localizedDescription)
            throw error
        }
        self.engine = engine
        state = .listening(level: 0)
        silenceDetector.reset()
    }

    public func stopListening() {
        stopEngineSilently()
        transcriber?.stop()
        silenceDetector.reset()
        if case .failed = state {
            // keep failure visible until next explicit action
        } else {
            state = .stopped
        }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Hands-free silence tracking: closes the mic when an utterance ends
    /// (or the capture cap hits) so STT finals auto-send with no second tap.
    /// Only when opted in AND a transcriber is attached — level-only metering
    /// is never auto-closed.
    private func ingestLevelForAutoStop(level: Float) {
        guard autoStopOnSilence, state.isCapturing else { return }
        guard transcriber != nil else { return }
        switch silenceDetector.ingest(level: level, at: Date()) {
        case .none:
            break
        case .utteranceEnded, .captureTimedOut:
            stopListening()
        }
    }

    /// Forwards copied samples to the attached transcriber (MainActor —
    /// called from the tap's MainActor hop with Sendable values only).
    /// Internal (not private) so unit tests can prove the mono contract.
    /// Samples are ALWAYS mono channel-0 extracts (see `copyMonoSamples`),
    /// so channels is hardcoded to 1: forwarding the tap's channel count
    /// would leave the recognizer's other channels uninitialized when the
    /// input is stereo. The `channels` parameter documents the tap facts.
    func forwardTranscription(samples: [Float], sampleRate: Double, channels: Int) {
        guard !samples.isEmpty else { return }
        transcriber?.ingestAudio(samples: samples, sampleRate: sampleRate, channels: 1)
    }

    // MARK: - Interruptions (calls, Siri, alarm...)

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            // Parse synchronously: Notification.userInfo ([AnyHashable: Any])
            // is not Sendable and must not cross into the task below.
            let type: AVAudioSession.InterruptionType? = {
                guard let info = note.userInfo,
                      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt else { return nil }
                return AVAudioSession.InterruptionType(rawValue: raw)
            }()
            Task { @MainActor [weak self] in
                self?.applyInterruption(type)
            }
        }
    }

    private func applyInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard let type else { return }
        switch type {
        case .began:
            // System took the mic — stop cleanly, UI returns to stopped.
            stopEngineSilently()
            state = .stopped
        case .ended:
            // Do NOT auto-resume (privacy). User taps mic again.
            if state.isCapturing { state = .stopped }
        @unknown default:
            break
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        applyInterruption(type)
    }

    private func stopEngineSilently() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: - DSP helpers (pure, unit-testable)

    static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let s = channel[i]
            sum += s * s
        }
        return min(1.0, sqrt(sum / Float(count)) * 4)
    }

    /// Copies channel 0 into a Sendable array for STT ingest. Pure function —
    /// safe on the audio thread. Empty when the buffer isn't float PCM.
    static func copyMonoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?.pointee else { return [] }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}
