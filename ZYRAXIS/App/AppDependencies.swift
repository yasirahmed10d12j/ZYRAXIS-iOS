import Foundation
import Combine

/// Dependency container wiring protocols -> implementations.
///
/// UI depends on this container (injected as `EnvironmentObject`), never on
/// concrete types directly — so phases swap implementations without
/// touching views.
///
/// Phase 2 layering (Phase 6 adds direct providers):
/// UI -> ConversationManager -> AIService (mock | backend | gemini | groq) -> ToolRegistry -> API/Backend
///          ↳ ContextManager (bounded context) · FastCommandRouter · AssistantStateMachine
@MainActor
public final class AppDependencies: ObservableObject {

    public let stateMachine: AssistantStateMachine
    public let settings: SettingsStore
    public let keychain: any KeychainService
    public let apiClient: any APIClient
    public let webSocket: URLSessionWebSocketManager
    public let voiceManager: VoiceManagerImpl
    public let memoryService: any MemoryService
    public let taskService: any TaskService
    public let notifications: any NotificationService
    public let toolRegistry: any ToolRegistry
    public let visionService: any VisionService
    public let conversation: ConversationManager

    private let mockService: any AIService
    private let backendService: BackendAIService
    private let geminiService: GeminiDirectService
    private let groqService: GroqDirectService
    private let contactService: (any ContactService)?

    /// Resolved per access from settings: direct providers call Gemini/Groq
    /// with the user's Keychain key; backend needs its server; else mock.
    public var aiService: any AIService {
        switch settings.selectedProvider {
        case .customBackend:
            return backendService
        case .gemini:
            return geminiService
        case .groq:
            return groqService
        case .mock, .realtimeFuture:
            return mockService
        }
    }

    /// Transcript + activity feed, owned by the conversation engine.
    public var messages: [ConversationMessage] { conversation.messages }
    public var activities: [AssistantActivity] { conversation.activities }
    public var isStreaming: Bool { conversation.isStreaming }
    /// Last observed backend HTTP status (DEBUG diagnostics).
    public var backendHttpStatus: Int? { backendService.lastHttpStatus }

    private var bag = Set<AnyCancellable>()

    public init(
        stateMachine: AssistantStateMachine,
        settings: SettingsStore,
        keychain: any KeychainService,
        apiClient: any APIClient,
        webSocket: URLSessionWebSocketManager,
        mockService: any AIService,
        backendService: BackendAIService,
        // Optional with in-body fallback for the same isolation reason as in
        // ConversationManager: default-argument expressions are nonisolated.
        geminiService: GeminiDirectService? = nil,
        groqService: GroqDirectService? = nil,
        contactService: (any ContactService)? = nil,
        voiceManager: VoiceManagerImpl,
        memoryService: any MemoryService,
        taskService: any TaskService,
        notifications: any NotificationService,
        toolRegistry: any ToolRegistry,
        visionService: any VisionService,
        contextManager: ContextManager = ContextManager()
    ) {
        self.stateMachine = stateMachine
        self.settings = settings
        self.keychain = keychain
        self.apiClient = apiClient
        self.webSocket = webSocket
        self.mockService = mockService
        self.backendService = backendService
        self.geminiService = geminiService ?? GeminiDirectService()
        self.groqService = groqService ?? GroqDirectService()
        self.contactService = contactService
        self.voiceManager = voiceManager
        self.memoryService = memoryService
        self.taskService = taskService
        self.notifications = notifications
        self.toolRegistry = toolRegistry
        self.visionService = visionService
        self.conversation = ConversationManager(
            stateMachine: stateMachine,
            settings: settings,
            memoryService: memoryService,
            toolRegistry: toolRegistry,
            contextManager: contextManager,
            mockService: mockService,
            backendService: backendService,
            geminiService: geminiService,
            groqService: groqService,
            contactService: contactService
        )

        // Forward nested ObservableObject changes so views observing only
        // `AppDependencies` still refresh when children change.
        stateMachine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        voiceManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        webSocket.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        conversation.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// Default Phase 4 wiring: mock AI for UI dev + real backend service
    /// (active when the backend provider is selected and configured) +
    /// real Apple STT / AVSpeech TTS (both opt-in via Settings) +
    /// the safe read-only AppInfoTool for E2E tool round-trips.
    public static func makeDefault() -> AppDependencies {
        let settings = SettingsStore()
        let keychain: any KeychainService = SystemKeychainService()
        let config = settings.backendConfig
        let api: any APIClient = URLSessionAPIClient(config: config)
        let ws = URLSessionWebSocketManager()
        ws.reconnectPolicy = config.reconnectPolicy
        let mock: any AIService = MockAIService(delayNanoseconds: AppConfig.mockAIDelay)
        let gemini = GeminiDirectService(
            keychain: keychain,
            timeout: settings.requestTimeout
        )
        let groq = GroqDirectService(
            keychain: keychain,
            timeout: settings.requestTimeout
        )
        let backend = BackendAIService(
            socket: ws,
            api: api,
            auth: KeychainAuthProvider(keychain: keychain),
            configProvider: { [weak settings] in
                settings?.backendConfig ?? .default
            }
        )
        let voice = VoiceManagerImpl()
        let contacts: any ContactService = SystemContactService()
        let stt = AppleSpeechTranscriber()
        voice.transcriber = stt
        let tts = AVSpeechService()
        let memory: any MemoryService = SyncedMemoryService(
            local: InMemoryMemoryService(),
            api: api,
            auth: KeychainAuthProvider(keychain: keychain),
            configProvider: { [weak settings] in settings?.backendConfig ?? .default }
        )
        let notifications: any NotificationService = UNNotificationService()
        let tasks: any TaskService = SyncedTaskService(
            local: LocalTaskService(notifications: notifications),
            api: api,
            auth: KeychainAuthProvider(keychain: keychain),
            configProvider: { [weak settings] in settings?.backendConfig ?? .default }
        )
        let tools: any ToolRegistry = DefaultToolRegistry(seed: [AppInfoTool(), DeviceInfoTool(), NotificationTool(), AlarmTool(), EmailTool()])
        let vision: any VisionService = UnimplementedVisionService()
        let sm = AssistantStateMachine()
        let deps = AppDependencies(
            stateMachine: sm,
            settings: settings,
            keychain: keychain,
            apiClient: api,
            webSocket: ws,
            mockService: mock,
            backendService: backend,
            geminiService: gemini,
            groqService: groq,
            contactService: contacts,
            voiceManager: voice,
            memoryService: memory,
            taskService: tasks,
            notifications: notifications,
            toolRegistry: tools,
            visionService: vision
        )
        // Voice loop: mic → STT → ConversationManager. Finals auto-send;
        // partials only hint speaking state (never fabricated into messages).
        deps.conversation.speechService = tts
        // Server push: dashboard remote commands arrive on the backend socket
        // at any time (even idle) and run through the engine's fast path.
        backend.remoteCommandHandler = { [weak deps] command in
            guard let conversation = deps?.conversation else { return }
            Task { @MainActor [weak conversation] in
                await conversation?.handleRemoteCommand(command)
            }
        }
        stt.transcripts.sink { [weak deps] transcript in
            guard let conversation = deps?.conversation else { return }
            Task { @MainActor [weak conversation] in
                await conversation?.acceptExternalTranscript(transcript.text, isFinal: transcript.isFinal)
            }
        }.store(in: &deps.bag)
        return deps
    }

    // MARK: - Conversation use-cases (UI calls these; engine does the work)

    /// Sends a user message through the fast-path + streaming AI engine.
    public func sendUserMessage(_ text: String) async {
        await conversation.send(text)
    }

    /// User-pressed Stop/Cancel.
    public func cancelCurrentRequest() {
        conversation.cancel()
    }

    public func pushActivity(_ activity: AssistantActivity) {
        conversation.pushActivity(activity)
    }

    public func clearTranscript() {
        conversation.clear()
    }

    /// Forwards fast-command mic requests to the UI's voice handler.
    public func setVoiceControlHandler(_ handler: ((FastCommandMicAction) -> Void)?) {
        conversation.voiceControlHandler = handler
    }

    /// Opens validated external URLs from fast-path open commands.
    /// Forwarded to the conversation engine (which owns the handler slot).
    public var openURLHandler: ((OpenRequest) -> Void)? {
        get { conversation.openURLHandler }
        set { conversation.openURLHandler = newValue }
    }
}
