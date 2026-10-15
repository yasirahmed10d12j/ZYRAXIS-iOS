import Foundation
import Combine

/// Persisted user settings. Backed by UserDefaults (non-secret only).
/// Secrets (API keys) always go to KeychainService — never here.
///
/// Phase 4 fix: mutations persist to the injected `defaults` instance, not
/// unconditionally to `.standard` (previously test-suite instances leaked
/// writes into standard defaults).
@MainActor
public final class SettingsStore: ObservableObject {

    public enum Appearance: String, CaseIterable, Identifiable {
        case system, dark, light
        public var id: String { rawValue }
    }

    /// Which HTTP backend the active config resolves from.
    public enum BackendEnvironment: String, CaseIterable, Identifiable {
        case production
        case staging
        case development
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .production: return "Production"
            case .staging: return "Staging"
            case .development: return "Development"
            }
        }
    }

    @Published public var backendBaseURLString: String {
        didSet { defaults.set(backendBaseURLString, forKey: Keys.backendURL) }
    }
    @Published public var websocketURLString: String {
        didSet { defaults.set(websocketURLString, forKey: Keys.wsURL) }
    }
    @Published public var requestTimeout: Double {
        didSet { defaults.set(requestTimeout, forKey: Keys.timeout) }
    }
    @Published public var connectionTimeout: Double {
        didSet { defaults.set(connectionTimeout, forKey: Keys.connectionTimeout) }
    }
    @Published public var environment: BackendEnvironment {
        didSet { defaults.set(environment.rawValue, forKey: Keys.environment) }
    }
    @Published public var devBaseURLString: String {
        didSet { defaults.set(devBaseURLString, forKey: Keys.devBackendURL) }
    }
    @Published public var devWebSocketURLString: String {
        didSet { defaults.set(devWebSocketURLString, forKey: Keys.devWSURL) }
    }
    @Published public var stagingBaseURLString: String {
        didSet { defaults.set(stagingBaseURLString, forKey: Keys.stagingBackendURL) }
    }
    @Published public var stagingWebSocketURLString: String {
        didSet { defaults.set(stagingWebSocketURLString, forKey: Keys.stagingWSURL) }
    }
    @Published public var selectedProvider: AIProvider {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: Keys.provider)
        }
    }
    @Published public var voiceEnabled: Bool {
        didSet { defaults.set(voiceEnabled, forKey: Keys.voice) }
    }
    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }
    @Published public var memoryEnabled: Bool {
        didSet { defaults.set(memoryEnabled, forKey: Keys.memory) }
    }
    @Published public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    /// Spoken responses via SpeechService. Default OFF — text works standalone.
    @Published public var voiceResponsesEnabled: Bool {
        didSet { defaults.set(voiceResponsesEnabled, forKey: Keys.voiceResponses) }
    }
    /// Live mic → STT → ConversationManager loop. Default OFF — mic stays at
    /// level metering until the user opts into transcription.
    @Published public var liveTranscriptionEnabled: Bool {
        didSet { defaults.set(liveTranscriptionEnabled, forKey: Keys.liveTranscription) }
    }
    /// STT recognizer locale: BCP-47 identifier ("en-US", "ur-PK", "hi-IN")
    /// or "system" for the device default.
    @Published public var sttLocale: String {
        didSet { defaults.set(sttLocale, forKey: Keys.sttLocale) }
    }
    /// Nil when `sttLocale` is "system".
    public var sttLocaleIdentifier: String? {
        sttLocale == "system" ? nil : sttLocale
    }
    /// TTS speaking rate 0.0...1.0 (system default 0.5).
    @Published public var ttsRate: Float {
        didSet { defaults.set(ttsRate, forKey: Keys.ttsRate) }
    }
    /// Explicit TTS voice identifier, or nil/empty for system default.
    @Published public var ttsVoiceIdentifier: String {
        didSet { defaults.set(ttsVoiceIdentifier, forKey: Keys.ttsVoice) }
    }
    /// Hands-free auto-send silence threshold, seconds (0.6...3.0).
    @Published public var handsFreeSilenceSeconds: Double {
        didSet { defaults.set(handsFreeSilenceSeconds, forKey: Keys.handsFreeSilence) }
    }
    /// Hands-free loop: mic auto-closes on utterance end (STT final auto-sends)
    /// and re-opens after each voice turn. Default OFF — explicit opt-in only.
    @Published public var handsFreeMode: Bool {
        didSet { defaults.set(handsFreeMode, forKey: Keys.handsFree) }
    }
    /// Reduce Motion: static core (no rotation/pulse), for older devices or
    /// users sensitive to animation. Purely visual — behavior unchanged.
    @Published public var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Keys.reduceMotion) }
    }
    /// Stable per-install device identity (random UUID — NOT a hardware ID,
    /// resettable by reinstall/reset). Sent ONLY to the user's own backend
    /// (session_start + hub sync) so the ecosystem recognizes this device
    /// across turns. Never to vendors, never in logs.
    @Published public var deviceId: String {
        didSet { defaults.set(deviceId, forKey: Keys.deviceId) }
    }

    /// The UserDefaults instance mutations persist to (`.standard` by
    /// default; isolated suites in tests).
    private let defaults: UserDefaults

    private enum Keys {
        static let backendURL = "zyraxis.settings.backendURL"
        static let wsURL = "zyraxis.settings.wsURL"
        static let timeout = "zyraxis.settings.timeout"
        static let connectionTimeout = "zyraxis.settings.connectionTimeout"
        static let environment = "zyraxis.settings.environment"
        static let devBackendURL = "zyraxis.settings.devBackendURL"
        static let devWSURL = "zyraxis.settings.devWSURL"
        static let stagingBackendURL = "zyraxis.settings.stagingBackendURL"
        static let stagingWSURL = "zyraxis.settings.stagingWSURL"
        static let provider = "zyraxis.settings.provider"
        static let voice = "zyraxis.settings.voice"
        static let notifications = "zyraxis.settings.notifications"
        static let memory = "zyraxis.settings.memory"
        static let appearance = "zyraxis.settings.appearance"
        static let voiceResponses = "zyraxis.settings.voiceResponses"
        static let handsFree = "zyraxis.settings.handsFree"
        static let liveTranscription = "zyraxis.settings.liveTranscription"
        static let sttLocale = "zyraxis.settings.sttLocale"
        static let ttsRate = "zyraxis.settings.ttsRate"
        static let ttsVoice = "zyraxis.settings.ttsVoice"
        static let handsFreeSilence = "zyraxis.settings.handsFreeSilence"
        static let reduceMotion = "zyraxis.settings.reduceMotion"
        static let deviceId = "zyraxis.settings.deviceId"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        self.backendBaseURLString = d.string(forKey: Keys.backendURL) ?? ""
        self.websocketURLString = d.string(forKey: Keys.wsURL) ?? ""
        let t = d.double(forKey: Keys.timeout)
        self.requestTimeout = t > 0 ? t : 30
        let ct = d.double(forKey: Keys.connectionTimeout)
        self.connectionTimeout = ct > 0 ? ct : 10
        let rawEnv = d.string(forKey: Keys.environment) ?? BackendEnvironment.production.rawValue
        self.environment = BackendEnvironment(rawValue: rawEnv) ?? .production
        self.devBaseURLString = d.string(forKey: Keys.devBackendURL) ?? ""
        self.devWebSocketURLString = d.string(forKey: Keys.devWSURL) ?? ""
        self.stagingBaseURLString = d.string(forKey: Keys.stagingBackendURL) ?? ""
        self.stagingWebSocketURLString = d.string(forKey: Keys.stagingWSURL) ?? ""
        let rawProvider = d.string(forKey: Keys.provider) ?? AIProvider.gemini.rawValue
        self.selectedProvider = AIProvider(rawValue: rawProvider) ?? .mock
        // `bool(forKey:)` returns false when unset — default voice/memory/notifications ON.
        self.voiceEnabled = d.object(forKey: Keys.voice) as? Bool ?? true
        self.notificationsEnabled = d.object(forKey: Keys.notifications) as? Bool ?? true
        self.memoryEnabled = d.object(forKey: Keys.memory) as? Bool ?? true
        let rawAppearance = d.string(forKey: Keys.appearance) ?? Appearance.dark.rawValue
        self.appearance = Appearance(rawValue: rawAppearance) ?? .dark
        self.voiceResponsesEnabled = d.object(forKey: Keys.voiceResponses) as? Bool ?? false
        self.handsFreeMode = d.object(forKey: Keys.handsFree) as? Bool ?? false
        self.liveTranscriptionEnabled = d.object(forKey: Keys.liveTranscription) as? Bool ?? false
        self.sttLocale = d.string(forKey: Keys.sttLocale) ?? "system"
        let tr = d.object(forKey: Keys.ttsRate) as? Float ?? -1
        // 0.5 = AVSpeechUtteranceDefaultSpeechRate (kept literal so this
        // settings layer does not import AVFoundation).
        self.ttsRate = tr < 0 ? 0.5 : min(1.0, max(0.0, tr))
        self.ttsVoiceIdentifier = d.string(forKey: Keys.ttsVoice) ?? ""
        let hs = d.double(forKey: Keys.handsFreeSilence)
        self.handsFreeSilenceSeconds = hs > 0 ? min(3.0, max(0.6, hs)) : 1.2
        self.reduceMotion = d.object(forKey: Keys.reduceMotion) as? Bool ?? false
        if let saved = d.string(forKey: Keys.deviceId), !saved.isEmpty {
            self.deviceId = saved
        } else {
            let fresh = UUID().uuidString
            d.set(fresh, forKey: Keys.deviceId)
            self.deviceId = fresh
        }
    }

    /// Validated snapshot for the networking layer. The active HTTP base
    /// resolves from `environment`, falling back to production when the
    /// selected environment's URLs are unset.
    public var backendConfig: BackendConfig {
        let prodBase = BackendConfig.parseBaseURL(backendBaseURLString)
        let devBase = BackendConfig.parseBaseURL(devBaseURLString)
        let stagingBase = BackendConfig.parseBaseURL(stagingBaseURLString)
        let activeBase: URL?
        switch environment {
        case .development: activeBase = devBase ?? prodBase
        case .staging: activeBase = stagingBase ?? prodBase
        case .production: activeBase = prodBase
        }
        let prodWS = BackendConfig.parseWebSocketURL(websocketURLString)
        let devWS = BackendConfig.parseWebSocketURL(devWebSocketURLString)
        let stagingWS = BackendConfig.parseWebSocketURL(stagingWebSocketURLString)
        let activeWS: URL?
        switch environment {
        case .development: activeWS = devWS ?? prodWS
        case .staging: activeWS = stagingWS ?? prodWS
        case .production: activeWS = prodWS
        }
        return BackendConfig(
            baseURL: activeBase,
            websocketURL: activeWS,
            requestTimeout: requestTimeout,
            developmentBaseURL: devBase,
            productionBaseURL: prodBase,
            apiVersion: "v1",
            connectionTimeout: connectionTimeout,
            reconnectPolicy: .default
        )
    }

    public func resetToDefaults() {
        backendBaseURLString = ""
        websocketURLString = ""
        requestTimeout = 30
        connectionTimeout = 10
        environment = .production
        devBaseURLString = ""
        devWebSocketURLString = ""
        stagingBaseURLString = ""
        stagingWebSocketURLString = ""
        selectedProvider = .gemini
        voiceEnabled = true
        notificationsEnabled = true
        memoryEnabled = true
        appearance = .dark
        voiceResponsesEnabled = false
        handsFreeMode = false
        sttLocale = "system"
        ttsRate = 0.5
        ttsVoiceIdentifier = ""
        handsFreeSilenceSeconds = 1.2
        liveTranscriptionEnabled = false
        reduceMotion = false
        deviceId = UUID().uuidString
    }
}
