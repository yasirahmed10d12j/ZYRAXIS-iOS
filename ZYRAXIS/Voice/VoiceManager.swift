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

@MainActor
public final class VoiceManagerImpl: ObservableObject, VoiceManager {

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

    public func configureAudioSession() throws {
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
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
    }

    public func stopListening() {
        stopEngineSilently()
        transcriber?.stop()
        if case .failed = state {
            // keep failure visible until next explicit action
        } else {
            state = .stopped
        }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Forwards copied samples to the attached transcriber (MainActor —
    /// called from the tap's MainActor hop with Sendable values only).
    private func forwardTranscription(samples: [Float], sampleRate: Double, channels: Int) {
        guard !samples.isEmpty else { return }
        transcriber?.ingestAudio(samples: samples, sampleRate: sampleRate, channels: channels)
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
