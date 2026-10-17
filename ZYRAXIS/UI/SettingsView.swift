import SwiftUI
import AVFoundation

/// Settings screen: placeholders + real controls.
///
/// Real: backend URL editing, timeout, provider picker (mock/backend/direct),
/// voice/notification/memory toggles, appearance, API-key keychain field,
/// reset. Everything else is an honest placeholder for later phases.
public struct SettingsView: View {

    @EnvironmentObject private var deps: AppDependencies
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput: String = ""
    @State private var keychainStatus: String = ""
    @State private var showingResetConfirm = false
    @State private var deviceSnapshot = DeviceInfoProvider.collect()
    @State private var wolMACInput: String = ""
    @State private var wolBroadcastInput: String = ""
    @State private var wolStatus: String = ""
    @State private var remoteDesktopSessionKey: String = ""

    public init() {}

    // MARK: - Provider-aware API key

    /// Keychain key for the currently selected provider. Direct providers
    /// each have their own key; the backend keeps its own.
    private var activeKeychainKey: String {
        switch deps.settings.selectedProvider {
        case .gemini:
            return KeychainKeys.geminiAPIKey
        case .groq:
            return KeychainKeys.groqAPIKey
        default:
            return KeychainKeys.backendAPIKey
        }
    }

    private var apiKeyFieldLabel: String {
        switch deps.settings.selectedProvider {
        case .gemini:
            return "Gemini API key (Keychain)"
        case .groq:
            return "Groq API key (Keychain)"
        default:
            return "Backend API key (Keychain)"
        }
    }

    // MARK: - Bindings (explicit so nested SettingsStore works via EnvironmentObject)

    private func binding<T>(get: @escaping (SettingsStore) -> T, set: @escaping (SettingsStore, T) -> Void) -> Binding<T> {
        Binding(
            get: { get(deps.settings) },
            set: { newValue in set(deps.settings, newValue) }
        )
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ZyraxisTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    aiBackendSection
                    voiceSection
                    notificationsSection
                    appearanceSection
                    privacySection
                    memorySection
                    deviceSection
                    wolSection
                    remoteDesktopSection
                    connectionSection
                    #if DEBUG
                    diagnosticsSection
                    #endif
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("ZYRAXIS Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                loadKeychainStatus()
                wolMACInput = deps.settings.wolMACAddress
                wolBroadcastInput = deps.settings.wolBroadcastAddress
                remoteDesktopSessionKey = deps.settings.remoteDesktopSessionKey
            }
            .onChange(of: deps.settings.selectedProvider) { _, _ in
                apiKeyInput = ""
                loadKeychainStatus()
            }
            .alert("Reset all settings?", isPresented: $showingResetConfirm) {
                Button("Reset", role: .destructive) {
                    deps.settings.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Sections

    private var aiBackendSection: some View {
        Section("AI Backend") {
            Picker("Provider", selection: binding(get: { $0.selectedProvider }, set: { $0.selectedProvider = $1 })) {
                ForEach(AIProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            Picker("Environment", selection: binding(get: { $0.environment }, set: { $0.environment = $1 })) {
                ForEach(SettingsStore.BackendEnvironment.allCases) { e in
                    Text(e.displayName).tag(e)
                }
            }
            TextField("Backend base URL (https://…)", text: binding(get: { $0.backendBaseURLString }, set: { $0.backendBaseURLString = $1 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Dev backend URL (https://…)", text: binding(get: { $0.devBaseURLString }, set: { $0.devBaseURLString = $1 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("WebSocket URL (wss://…)", text: binding(get: { $0.websocketURLString }, set: { $0.websocketURLString = $1 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Dev WebSocket URL (wss://…)", text: binding(get: { $0.devWebSocketURLString }, set: { $0.devWebSocketURLString = $1 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Staging backend URL (https://…)", text: binding(get: { $0.stagingBaseURLString }, set: { $0.stagingBaseURLString = $1 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Staging WebSocket URL (wss://…)", text: binding(get: { $0.stagingWebSocketURLString }, set: { $0.stagingWebSocketURLString = $1 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text("Request timeout")
                Spacer()
                Text("\(Int(deps.settings.requestTimeout))s")
                    .font(ZyraxisTheme.tech(12))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding(get: { $0.requestTimeout }, set: { $0.requestTimeout = $1 }), in: 5...120, step: 5)
            HStack {
                Text("Connection timeout")
                Spacer()
                Text("\(Int(deps.settings.connectionTimeout))s")
                    .font(ZyraxisTheme.tech(12))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding(get: { $0.connectionTimeout }, set: { $0.connectionTimeout = $1 }), in: 5...60, step: 5)
            SecureField(apiKeyFieldLabel, text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Save key") { saveKey() }
                Button("Delete key", role: .destructive) { deleteKey() }
                Spacer()
            }
            .buttonStyle(.borderless)
            if !keychainStatus.isEmpty {
                Text(keychainStatus)
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.secondary)
            }
            if deps.settings.selectedProvider == .mock {
                Text("Mock provider: canned [MOCK] replies for UI testing. Never real AI.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.secondary)
            } else if deps.settings.selectedProvider == .customBackend {
                Text("Backend provider: requires a running ZYRAXIS backend (HTTP + WebSocket, protocol v1) and a Keychain API key.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(deps.settings.backendConfig.isConfigured ? .secondary : ZyraxisTheme.warning)
            } else if deps.settings.selectedProvider == .gemini {
                Text("Gemini (direct): uses your free AI Studio key from Keychain — no backend server. Get a key at aistudio.google.com.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.secondary)
            } else if deps.settings.selectedProvider == .groq {
                Text("Groq (direct): uses your free console.groq.com key from Keychain — no backend server.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.secondary)
            } else {
                Text("Realtime provider is not implemented yet.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(ZyraxisTheme.warning)
            }
        }
    }

    private var voiceSection: some View {
        Section("Voice & Microphone") {
            Toggle("Voice input enabled", isOn: binding(get: { $0.voiceEnabled }, set: { $0.voiceEnabled = $1 }))
            Toggle("Hands-free loop (auto-send + re-listen)", isOn: binding(get: { $0.handsFreeMode }, set: { $0.handsFreeMode = $1 }))
            HStack {
                Text("Auto-send silence")
                Spacer()
                Text(String(format: "%.1fs", deps.settings.handsFreeSilenceSeconds))
                    .font(ZyraxisTheme.tech(12))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding(get: { $0.handsFreeSilenceSeconds }, set: { $0.handsFreeSilenceSeconds = $1 }), in: 0.6...3.0, step: 0.1)
            Toggle("Live transcription (STT)", isOn: binding(get: { $0.liveTranscriptionEnabled }, set: { $0.liveTranscriptionEnabled = $1 }))
            Picker("Recognizer language", selection: binding(get: { $0.sttLocale }, set: { $0.sttLocale = $1 })) {
                Text("System default").tag("system")
                Text("English (US)").tag("en-US")
                Text("Urdu").tag("ur-PK")
                Text("Hindi").tag("hi-IN")
            }
            Toggle("Voice responses (TTS)", isOn: binding(get: { $0.voiceResponsesEnabled }, set: { $0.voiceResponsesEnabled = $1 }))
            HStack {
                Text("Speech rate")
                Spacer()
                Text(String(format: "%.2f", deps.settings.ttsRate))
                    .font(ZyraxisTheme.tech(12))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding(get: { $0.ttsRate }, set: { $0.ttsRate = $1 }), in: 0.25...1.0, step: 0.05)
            Picker("Voice", selection: binding(get: { $0.ttsVoiceIdentifier }, set: { $0.ttsVoiceIdentifier = $1 })) {
                Text("System default").tag("")
                Section("Recommended (natural)") {
                    ForEach(AVSpeechService.recommendedVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))\(voice.quality == .enhanced ? " ⭐" : "")").tag(voice.identifier)
                    }
                }
                Section("All voices") {
                    ForEach(AVSpeechService.allVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
            }
            Toggle("Hands-free loop (auto-send + re-listen)", isOn: binding(get: { $0.handsFreeMode }, set: { $0.handsFreeMode = $1 }))
            Toggle("Voice responses (TTS)", isOn: binding(get: { $0.voiceResponsesEnabled }, set: { $0.voiceResponsesEnabled = $1 }))
            LabeledRow(
                title: "Microphone state",
                value: deps.voiceManager.voiceState.displayLabel
            )
            LabeledRow(
                title: "Speech recognition",
                value: (deps.voiceManager.transcriber?.isAvailable ?? false) ? "AVAILABLE" : "UNAVAILABLE"
            )
            Button("Request microphone permission") {
                Task { @MainActor [weak deps] in
                    _ = await deps?.voiceManager.requestPermission()
                }
            }
            Button("Request speech recognition permission") {
                Task { @MainActor [weak deps] in
                    _ = await deps?.voiceManager.transcriber?.requestPermission()
                }
            }
            Text("Mic capture + level metering are real. Live transcription uses Apple Speech (opt-in); finals auto-send, partials only animate state. Voice responses use AVSpeechSynthesizer (opt-in). Nothing is fabricated.")
                .font(ZyraxisTheme.caption())
                .foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Task reminders", isOn: binding(get: { $0.notificationsEnabled }, set: { $0.notificationsEnabled = $1 }))
            Button("Request notification permission") {
                Task { [weak deps] in
                    try? await deps?.notifications.requestAuthorization()
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: binding(get: { $0.appearance }, set: { $0.appearance = $1 })) {
                Text("Dark (default)").tag(SettingsStore.Appearance.dark)
                Text("System").tag(SettingsStore.Appearance.system)
                Text("Light").tag(SettingsStore.Appearance.light)
            }
            Text("ZYRAXIS is dark-first; light mode is provided for accessibility.")
                .font(ZyraxisTheme.caption())
                .foregroundStyle(.secondary)
            Toggle("Reduce Motion (static core, less battery)", isOn: binding(get: { $0.reduceMotion }, set: { $0.reduceMotion = $1 }))
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Text("Secrets are stored in Keychain only. No API keys in source or UserDefaults. Mic/camera/notification permissions are requested on use with purpose strings in Info.plist.")
                .font(ZyraxisTheme.caption())
            Button("Clear transcript") { deps.clearTranscript() }
        }
    }

    private var memorySection: some View {
        Section("Memory") {
            Toggle("Personal memory", isOn: binding(get: { $0.memoryEnabled }, set: { $0.memoryEnabled = $1 }))
            Text("Phase 1 uses on-device in-memory storage. Backend sync arrives later.")
                .font(ZyraxisTheme.caption())
                .foregroundStyle(.secondary)
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            LabeledRow(title: "Model", value: deviceSnapshot.modelIdentifier)
            LabeledRow(title: "iOS", value: deviceSnapshot.osVersion)
            LabeledRow(title: "App", value: deviceSnapshot.appVersion)
            LabeledRow(title: "CPU cores", value: "\(deviceSnapshot.cpuCount)")
            LabeledRow(title: "Memory (total)", value: DeviceInfoProvider.displayBytes(deviceSnapshot.totalMemoryBytes))
            LabeledRow(title: "Memory (this app)", value: DeviceInfoProvider.displayBytes(deviceSnapshot.appFootprintBytes))
            if let total = deviceSnapshot.storageTotalBytes, let free = deviceSnapshot.storageFreeBytes {
                LabeledRow(title: "Storage free", value: "\(DeviceInfoProvider.displayBytes(free)) of \(DeviceInfoProvider.displayBytes(total))")
            } else {
                LabeledRow(title: "Storage free", value: "—")
            }
            LabeledRow(title: "Battery", value: "\(DeviceInfoProvider.displayBattery(deviceSnapshot.batteryLevel)) (\(deviceSnapshot.batteryState))")
            LabeledRow(title: "Thermal state", value: deviceSnapshot.thermalState)
            LabeledRow(title: "Low power mode", value: deviceSnapshot.lowPowerMode ? "ON" : "OFF")
            Button("Refresh") { deviceSnapshot = DeviceInfoProvider.collect() }
            Text("Live values from iOS. No CPU-frequency or system-wide free-RAM API exists — those numbers are not shown rather than faked.")
                .font(ZyraxisTheme.caption())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Wake-on-LAN

    private var wolSection: some View {
        Section("Wake-on-LAN (Office PC)") {
            HStack {
                Text("MAC")
                Spacer()
                TextField("AA:BB:CC:DD:EE:FF", text: $wolMACInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(ZyraxisTheme.tech(12))
            }
            HStack {
                Text("Broadcast")
                Spacer()
                TextField("255.255.255.255", text: $wolBroadcastInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(ZyraxisTheme.tech(12))
            }
            HStack {
                Button("Save MAC") {
                    Task {
                        await saveWoLConfig()
                    }
                }
                Button("Power On") {
                    Task {
                        await powerOn()
                    }
                }
                .disabled(deps.settings.wolMACAddress.isEmpty)
                Spacer()
                if !wolStatus.isEmpty {
                    Text(wolStatus)
                        .font(ZyraxisTheme.caption())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            Text("Office desktop MAC (from `ipconfig` on the LAN PC). Power On sends a magic packet via your hub — WoL must be enabled in BIOS + Windows adapter settings, and the PC must be on AC power.")
                .font(ZyraxisTheme.caption())
                .foregroundStyle(.secondary)
        }
    }

    private var remoteDesktopSection: some View {
        Section("Remote Desktop") {
            HStack {
                Text("Session Key")
                Spacer()
                TextField("Desktop session key", text: $remoteDesktopSessionKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(ZyraxisTheme.tech(12))
            }
            Button {
                deps.settings.remoteDesktopSessionKey = remoteDesktopSessionKey
                let vc = RemoteDesktopViewController(
                    service: deps.remoteDesktopService,
                    sessionKey: deps.settings.remoteDesktopSessionKey
                )
                let nav = UINavigationController(rootViewController: vc)
                present(nav, animated: true)
            } label: {
                HStack {
                    Image(systemName: "desktopcomputer")
                    Text("Connect to Desktop")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(deps.settings.remoteDesktopSessionKey.isEmpty)

            Text("Desktop must be running ZYRAXIS server with remote desktop enabled. Get session key from desktop app.")
                .font(ZyraxisTheme.caption())
                .foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledRow(
                title: "Backend",
                value: deps.settings.backendConfig.isConfigured ? "CONFIGURED" : "NOT CONFIGURED"
            )
            LabeledRow(title: "Environment", value: deps.settings.environment.displayName)
            LabeledRow(title: "Socket", value: deps.webSocket.state.displayLabel)
            LabeledRow(title: "Reconnect", value: "≤\(deps.settings.backendConfig.reconnectPolicy.maxAttempts) attempts, exp backoff")
            if let url = deps.settings.backendConfig.websocketURL {
                Button("Connect WebSocket") { deps.webSocket.connect(url: url) }
                Button("Disconnect", role: .destructive) { deps.webSocket.disconnect() }
            } else {
                Text("Set a wss:// URL above to enable the WebSocket test buttons.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }

    #if DEBUG
    /// Development-only connection diagnostics. Every value is real or "—";
    /// nothing is synthesized. No tokens or credentials are ever shown —
    /// backend hosts are scheme + host only (see DiagnosticsSupport).
    private var diagnosticsSection: some View {
        Section("Diagnostics (DEBUG)") {
            let config = deps.settings.backendConfig
            LabeledRow(title: "Backend host", value: DiagnosticsSupport.sanitizedHostString(for: config.baseURL))
            LabeledRow(title: "Socket host", value: DiagnosticsSupport.sanitizedHostString(for: config.websocketURL))
            LabeledRow(title: "HTTP status", value: deps.backendHttpStatus.map(String.init) ?? "—")
            LabeledRow(title: "Socket", value: deps.webSocket.state.displayLabel)
            LabeledRow(title: "Reconnects", value: "\(deps.webSocket.reconnectCount)")
            LabeledRow(title: "Last connected", value: DiagnosticsSupport.dateString(for: deps.webSocket.lastConnectedAt))
            LabeledRow(title: "Last error", value: deps.stateMachine.lastError?.localizedDescription ?? "—")
            LabeledRow(
                title: "Ping round-trip",
                value: deps.webSocket.lastPingLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "—"
            )
            if let timing = deps.conversation.lastTiming {
                LabeledRow(title: "First token", value: timing.timeToFirstToken?.displayString ?? "—")
                LabeledRow(title: "Stream duration", value: timing.streamDuration?.displayString ?? "—")
                LabeledRow(title: "Total response", value: timing.totalResponseTime?.displayString ?? "—")
            } else {
                Text("No request timed yet — send a message first.")
                    .font(ZyraxisTheme.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif

    private var aboutSection: some View {
        Section("About ZYRAXIS") {
            LabeledRow(title: "Version", value: AppConfig.version)
            LabeledRow(title: "Target", value: AppConfig.targetDevice)
            LabeledRow(title: "Minimum iOS", value: AppConfig.minimumiOS)
            Text(AppConfig.tagline)
                .font(ZyraxisTheme.caption())
                .foregroundStyle(.secondary)
            Button("Reset all settings", role: .destructive) {
                showingResetConfirm = true
            }
        }
    }

    // MARK: - Keychain helpers

    private func saveKey() {
        do {
            try deps.keychain.save(apiKeyInput, forKey: activeKeychainKey)
            apiKeyInput = ""
            keychainStatus = "API key saved to Keychain."
        } catch {
            keychainStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    private func deleteKey() {
        do {
            try deps.keychain.delete(forKey: activeKeychainKey)
            keychainStatus = "API key deleted from Keychain."
        } catch {
            keychainStatus = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func loadKeychainStatus() {
        do {
            let existing = try deps.keychain.load(forKey: activeKeychainKey)
            keychainStatus = (existing?.isEmpty == false) ? "API key present in Keychain." : "No API key stored."
        } catch {
            keychainStatus = "Keychain unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: - WoL helpers

    private func saveWoLConfig() async {
        let mac = wolMACInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let broadcast = wolBroadcastInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "255.255.255.255" : wolBroadcastInput
        do {
            try await deps.wolService.configure(mac: mac, broadcast: broadcast)
            deps.settings.wolMACAddress = mac
            deps.settings.wolBroadcastAddress = broadcast
            wolStatus = "MAC saved to hub."
            wolMACInput = ""
            wolBroadcastInput = ""
        } catch {
            wolStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    private func powerOn() async {
        do {
            try await deps.wolService.wake()
            wolStatus = deps.wolService.lastStatus ?? "Magic packet sent."
        } catch {
            wolStatus = "Wake failed: \(error.localizedDescription)"
        }
    }
}

private struct LabeledRow: View {
    var title: String
    var value: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(ZyraxisTheme.tech(12))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppDependencies.makeDefault())
}
