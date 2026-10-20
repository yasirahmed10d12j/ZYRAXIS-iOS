import SwiftUI
import Combine
import UIKit
import AVFoundation

/// Premium futuristic ZYRAXIS home screen for iPhone.
///
/// Layout (top -> bottom):
/// - header: wordmark + connection badge + settings gear
/// - central animated core (state-reactive)
/// - status line + mic state
/// - activity feed (latest 3)
/// - transcript (glass panel)
/// - command input + mic button
///
/// Deliberately NOT a generic chatbot: technical console aesthetic,
/// state-driven illumination, transcript as a system log.
public struct MainAssistantView: View {

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.scenePhase) private var scenePhase
    @State private var inputText: String = ""
    @State private var micLevel: Float = 0
    @State private var showingSettings = false
    @State private var sendTask: Task<Void, Never>?
    @State private var shareText: String = ""
    @State private var showingShare = false
    // Background grace task (~30s): lets an in-flight reply finish after the
    // app backgrounds. iOS still suspends the app afterwards — this is NOT
    // continuous background listening (impossible for third-party apps).
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    public init() {}

    public var body: some View {
        ZStack {
            ZyraxisTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                ScrollView {
                    VStack(spacing: 16) {
                        ZyraxisCoreView(
                            state: deps.stateMachine.state,
                            micLevel: micLevel,
                            reduceMotion: deps.settings.reduceMotion
                        )
                        .padding(.top, 6)

                        statusBlock

                        if !deps.activities.isEmpty {
                            GlassPanel {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("// ACTIVITY")
                                        .font(ZyraxisTheme.tech(10))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .tracking(2)
                                    ForEach(deps.activities.prefix(3)) { act in
                                        ActivityRow(activity: act)
                                    }
                                }
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("// TRANSCRIPT")
                                        .font(ZyraxisTheme.tech(10))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .tracking(2)
                                    Spacer()
                                    if deps.aiService.provider == .mock {
                                        Text("MOCK PROVIDER")
                                            .font(ZyraxisTheme.tech(9))
                                            .foregroundStyle(ZyraxisTheme.warning)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(ZyraxisTheme.warning.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    Button("Clear") { deps.clearTranscript() }
                                        .font(ZyraxisTheme.tech(10))
                                        .foregroundStyle(.white.opacity(0.5))
                                    Button("Share") {
                                        shareText = deps.conversation.exportText()
                                        showingShare = !shareText.isEmpty
                                    }
                                    .font(ZyraxisTheme.tech(10))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .sheet(isPresented: $showingShare) {
                                        ShareSheet(items: [shareText])
                                    }
                                }
                                ConversationTranscriptView(messages: deps.messages)
                                    .frame(minHeight: 120, maxHeight: 300)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }

                bottomBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(dependencies: deps)
        }
        .onAppear {
            deps.setVoiceControlHandler { [weak deps] action in
                guard let deps else { return }
                Task { @MainActor [weak deps] in
                    guard let deps else { return }
                    switch action {
                    case .enableMic:
                        if !deps.voiceManager.voiceState.isCapturing {
                            await Self.startMic(deps)
                        }
                    case .disableMic:
                        if deps.voiceManager.voiceState.isCapturing {
                            Self.stopMic(deps)
                        }
                    }
                }
            }
            deps.openURLHandler = { [weak deps] request in
                UIApplication.shared.open(request.url, options: [:]) { [weak deps] opened in
                    Task { @MainActor [weak deps] in
                        deps?.pushActivity(.init(
                            kind: .system,
                            title: opened
                                ? "Opened \(request.label)"
                                : "Couldn't open \(request.label) on this iPhone"
                        ))
                    }
                }
            }
            deps.conversation.autoListenHandler = { [weak deps] in
                guard let deps else { return }
                Task { @MainActor [weak deps] in
                    guard let deps else { return }
                    await Self.startMic(deps)
                }
            }
            deps.conversation.systemActionHandler = { [weak deps] action in
                guard let deps else { return }
                Task { @MainActor in
                    switch action {
                    case .brightness(let level):
                        UIScreen.main.brightness = level
                        deps.pushActivity(.init(kind: .system, title: "Brightness set to \(Int(level * 100))%"))
                    case .brightnessUp:
                        UIScreen.main.brightness = min(1.0, UIScreen.main.brightness + 0.15)
                        deps.pushActivity(.init(kind: .system, title: "Brightness increased"))
                    case .brightnessDown:
                        UIScreen.main.brightness = max(0.05, UIScreen.main.brightness - 0.15)
                        deps.pushActivity(.init(kind: .system, title: "Brightness decreased"))
                    case .torch(let on):
                        if Self.setTorch(on: on) {
                            deps.pushActivity(.init(kind: .system, title: on ? "Flashlight on" : "Flashlight off"))
                        } else {
                            deps.pushActivity(.init(
                                kind: .error,
                                title: "Couldn't reach the flashlight",
                                detail: "This iPhone may have no torch, or Camera access is denied (iOS Settings → ZYRAXIS → Camera)."
                            ))
                        }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                beginBackgroundGrace()
            case .active:
                endBackgroundGrace()
            default:
                break
            }
        }
        .onReceive(deps.voiceManager.voiceStatePublisher) { vs in
            if case .listening(let lvl) = vs {
                micLevel = lvl
            } else {
                micLevel = 0
            }
        }
        .onDisappear {
            sendTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ZYRAXIS")
                    .font(ZyraxisTheme.tech(20))
                    .foregroundStyle(.white)
                    .tracking(6)
                Text(AppConfig.tagline.uppercased())
                    .font(ZyraxisTheme.tech(9))
                    .foregroundStyle(ZyraxisTheme.cyan.opacity(0.8))
                    .tracking(1)
            }
            Spacer()
            ConnectionBadge(
                connectionState: deps.webSocket.state,
                backendConfigured: providerConnectionConfigured
            )
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Open settings")
        }
    }

    // MARK: - Status

    /// ConnectionBadge "configured" flag per provider: backend and mock keep
    /// the legacy backend-URL behavior; direct providers are connectionless
    /// (badge then reflects socket state instead of claiming NO BACKEND).
    private var providerConnectionConfigured: Bool {
        switch deps.settings.selectedProvider {
        case .customBackend, .mock:
            return deps.settings.backendConfig.isConfigured
        case .gemini, .groq, .realtimeFuture:
            return true
        }
    }

    /// Whether the selected direct provider has a key in Keychain.
    private var hasDirectProviderKey: Bool {
        let key: String
        switch deps.settings.selectedProvider {
        case .gemini:
            key = KeychainKeys.geminiAPIKey
        case .groq:
            key = KeychainKeys.groqAPIKey
        default:
            return true
        }
        return (try? deps.keychain.load(forKey: key))?.isEmpty == false
    }

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(deps.stateMachine.state.displayLabel)
                .font(ZyraxisTheme.tech(13))
                .foregroundStyle(ZyraxisTheme.glow(for: deps.stateMachine.state))
                .tracking(2)
            HStack(spacing: 8) {
                Text(deps.voiceManager.voiceState.displayLabel)
                    .font(ZyraxisTheme.tech(10))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(1)
                if deps.isStreaming {
                    Text("● STREAMING")
                        .font(ZyraxisTheme.tech(10))
                        .foregroundStyle(ZyraxisTheme.cyan)
                        .tracking(1)
                }
                if let err = deps.stateMachine.lastError {
                    Text("— \(err.localizedDescription)")
                        .font(ZyraxisTheme.tech(10))
                        .foregroundStyle(ZyraxisTheme.warning)
                        .lineLimit(1)
                }
            }
            if deps.settings.backendConfig.isConfigured == false && deps.settings.selectedProvider == .customBackend {
                Text("Backend not configured — set URL in Settings.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            } else if deps.settings.selectedProvider == .mock {
                Text("Mock AI active for UI dev — select Gemini or Groq in Settings for real AI.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            } else if (deps.settings.selectedProvider == .gemini || deps.settings.selectedProvider == .groq) && !hasDirectProviderKey {
                Text("Add your \(deps.settings.selectedProvider.displayName) API key in Settings → AI Backend.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            CommandInputBar(
                text: $inputText,
                isBusy: isBusy
            ) {
                send()
            } onCancel: {
                cancel()
            }
            MicButton(
                assistantState: deps.stateMachine.state,
                voiceState: deps.voiceManager.voiceState
            ) {
                toggleVoice()
            }
        }
    }

    private var isBusy: Bool {
        [.processing, .speaking, .executing].contains(deps.stateMachine.state)
    }

    // MARK: - Intents

    private func send() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = ""
        sendTask?.cancel()
        // Weak deps: AppDependencies is a non-Sendable MainActor class and must
        // not be captured strongly by a nonisolated @Sendable task (Swift 6).
        sendTask = Task { [weak deps] in
            await deps?.sendUserMessage(text)
        }
    }

    /// User-pressed Stop: cancel the in-flight AI request.
    private func cancel() {
        sendTask?.cancel()
        deps.cancelCurrentRequest()
    }

    private func toggleVoice() {
        // Weak deps + static helpers: neither the non-Sendable AppDependencies
        // instance nor the View struct itself may be captured strongly by a
        // nonisolated @Sendable task (Swift 6).
        Task { @MainActor [weak deps] in
            guard let deps else { return }
            if deps.voiceManager.voiceState.isCapturing {
                Self.stopMic(deps)
            } else {
                await Self.startMic(deps)
            }
        }
    }

    private static func stopMic(_ deps: AppDependencies) {
        // End transcription first: mic-toggle-off is the utterance boundary,
        // so the trailing final still arrives and sends.
        deps.voiceManager.transcriber?.stop()
        deps.voiceManager.stopListening()
        deps.stateMachine.transition(to: .idle)
        deps.pushActivity(.init(kind: .listening, title: "Mic closed"))
    }

    /// Camera flashlight via AVCaptureDevice torch. Returns false when the
    /// device has no torch or Camera access is denied — the caller reports
    /// that honestly instead of pretending. Torch needs the video device,
    /// which is why Camera permission (already declared for Vision) applies.
    private static func setTorch(on: Bool) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            return true
        } catch {
            ZyraxisLogger.error(.voice, "torch failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Background grace: if a reply is streaming or the mic is capturing when
    /// the app backgrounds, ask iOS for ~30s to finish the in-flight turn.
    /// This does NOT keep the app alive: iOS suspends third-party apps and
    /// cuts the mic regardless — continuous background listening is
    /// impossible on stock iOS and is not attempted here.
    private func beginBackgroundGrace() {
        guard backgroundTask == .invalid else { return }
        guard deps.conversation.isStreaming || deps.voiceManager.voiceState.isCapturing else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "zyraxis-finish-turn") {
            ZyraxisLogger.log(.voice, "background grace expired")
        }
    }

    private func endBackgroundGrace() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private static func startMic(_ deps: AppDependencies) async {
        // Permission + capture are real; live transcription is opt-in.
        let perm = await deps.voiceManager.requestPermission()
        guard perm else {
            deps.stateMachine.fail(with: .voice("Microphone permission denied. Enable it in iOS Settings."))
            return
        }
        deps.voiceManager.configureHandsFree(enabled: deps.settings.handsFreeMode, silenceSeconds: deps.settings.handsFreeSilenceSeconds)
        do {
            try deps.voiceManager.startListening()
            deps.stateMachine.beginListening()
            deps.pushActivity(.init(
                kind: .listening,
                title: "Mic open — capturing level",
                detail: deps.settings.liveTranscriptionEnabled
                    ? "Live transcription on — speak, then close the mic to send."
                    : "Transcription off — enable it in Settings, or use text commands."
            ))
            if deps.settings.liveTranscriptionEnabled {
                await startTranscription(deps)
            }
        } catch {
            deps.stateMachine.fail(with: .voice(error.localizedDescription))
        }
    }

    /// Starts live STT without killing level-only capture on failure
    /// (graceful degradation: the mic stays open).
    private static func startTranscription(_ deps: AppDependencies) async {
        guard let stt = deps.voiceManager.transcriber else { return }
        guard await stt.requestPermission() else {
            deps.pushActivity(.init(
                kind: .error,
                title: "Speech recognition denied",
                detail: "Mic stays open for level metering. Enable Speech Recognition in iOS Settings."
            ))
            return
        }
        stt.applyLocale(identifier: deps.settings.sttLocaleIdentifier)
        do {
            try stt.start()
            deps.pushActivity(.init(kind: .listening, title: "Live transcription started"))
        } catch {
            deps.pushActivity(.init(
                kind: .error,
                title: "Transcription unavailable",
                detail: "\(error.localizedDescription) Mic stays open for level metering."
            ))
        }
    }
}

/// Thin `UIActivityViewController` wrapper for transcript export.
/// iPhone-only target, so no iPad popover source view is needed.
private struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    MainAssistantView()
        .environmentObject(AppDependencies.makeDefault())
}
