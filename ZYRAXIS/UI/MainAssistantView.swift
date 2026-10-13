import SwiftUI
import Combine

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
    @State private var inputText: String = ""
    @State private var micLevel: Float = 0
    @State private var showingSettings = false
    @State private var sendTask: Task<Void, Never>?

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
                            micLevel: micLevel
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
            SettingsView()
                .environmentObject(deps)
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
                backendConfigured: deps.settings.backendConfig.isConfigured
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
            if deps.settings.backendConfig.isConfigured == false {
                Text("Backend not configured — set URL in Settings. Mock AI active for UI dev.")
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

    private static func startMic(_ deps: AppDependencies) async {
        // Permission + capture are real; live transcription is opt-in.
        let perm = await deps.voiceManager.requestPermission()
        guard perm else {
            deps.stateMachine.fail(with: .voice("Microphone permission denied. Enable it in iOS Settings."))
            return
        }
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

#Preview {
    MainAssistantView()
        .environmentObject(AppDependencies.makeDefault())
}
