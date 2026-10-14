import Foundation
import Combine

/// Phase 2 conversation engine. Owns the transcript and drives real
/// streaming AI turns:
///
/// send → fast-path? → context build → stream deltas into a placeholder
/// message → completion/cancel/error → safe state recovery.
///
/// Guarantees:
/// - UI never touches WebSocket frames (only `messages`/`activities`/state).
/// - Every stream event is stale-guarded by `requestId` (cancelled or
///   superseded requests can never update the UI afterward).
/// - Duplicate deltas are dropped via per-request sequence numbers.
/// - Cancellation stops updates, notifies the service best-effort, and
///   returns to `.idle` through legal transitions only.
/// - ERROR stays recoverable: a new send auto-resets from `.error` to idle.
@MainActor
public final class ConversationManager: ObservableObject {

    @Published public private(set) var messages: [ConversationMessage] = []
    @Published public private(set) var activities: [AssistantActivity] = []
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var currentRequestId: UUID?
    /// Monotonic timing of the most recently finished request (T0…T4).
    @Published public private(set) var lastTiming: RequestTiming?

    /// Future STT hook target: mic on/off requests from fast commands are
    /// forwarded here. Set by the UI layer (which owns VoiceManager).
    public var voiceControlHandler: ((FastCommandMicAction) -> Void)?

    /// Opens validated external URLs from fast-path open commands. Set by the
    /// UI layer (which owns UIApplication); nil in tests unless injected.
    public var openURLHandler: ((OpenRequest) -> Void)?

    /// Re-opens the mic for hands-free looping. Set by the UI layer; invoked
    /// after a voice-initiated turn completes while hands-free mode is on.
    public var autoListenHandler: (() -> Void)?
    /// Executes device system actions (brightness, etc.) on the MainActor
    /// where UIScreen is available. Provided by the UI layer.
    public var systemActionHandler: ((SystemAction) -> Void)?

    /// Contact lookup for call/text/WhatsApp-by-name. Nil when unavailable
    /// (tests that never use it); contact commands then report an error.
    public var contactService: (any ContactService)?

    /// Task store for reminder commands. Nil when unavailable; reminder
    /// commands then report an error instead of pretending to save.
    public var taskService: (any TaskService)?

    /// True only while the in-flight turn was voice-initiated (STT final).
    /// Typed turns never set it, so hands-free re-listening never fires
    /// after typing. Consumed (reset) whenever it triggers or cancels.
    private var voiceInitiatedTurn = false

    /// Future TTS hook. Nil in Phase 2 → text-only responses (state still
    /// flows PROCESSING → SPEAKING → IDLE momentarily).
    public var speechService: (any SpeechService)?

    private let stateMachine: AssistantStateMachine
    private let settings: SettingsStore
    private let memoryService: any MemoryService
    private let toolRegistry: any ToolRegistry
    private let contextManager: ContextManager
    private let fastRouter: FastCommandRouter
    private let mockService: any AIService
    private let backendService: any AIService
    private let geminiService: GeminiDirectService
    private let groqService: GroqDirectService

    private var streamTask: Task<Void, Never>?
    private var lastSeq: [UUID: Int] = [:]
    private var accumulated: [UUID: String] = [:]
    private var placeholderId: [UUID: UUID] = [:]
    private var timingInFlight: RequestTiming?

    public init(
        stateMachine: AssistantStateMachine,
        settings: SettingsStore,
        memoryService: any MemoryService,
        toolRegistry: any ToolRegistry,
        contextManager: ContextManager = ContextManager(),
        fastRouter: FastCommandRouter = FastCommandRouter(),
        mockService: any AIService,
        backendService: any AIService,
        // Optional so existing call sites compile unchanged; nil resolves to
        // a default instance below. Default-argument expressions are
        // nonisolated, so `= GeminiDirectService()` here would not compile
        // (MainActor-isolated init called from a nonisolated context).
        geminiService: GeminiDirectService? = nil,
        groqService: GroqDirectService? = nil,
        contactService: (any ContactService)? = nil
    ) {
        self.stateMachine = stateMachine
        self.settings = settings
        self.memoryService = memoryService
        self.toolRegistry = toolRegistry
        self.contextManager = contextManager
        self.fastRouter = fastRouter
        self.mockService = mockService
        self.backendService = backendService
        self.geminiService = geminiService ?? GeminiDirectService()
        self.groqService = groqService ?? GroqDirectService()
        self.contactService = contactService
    }

    // MARK: - Service resolution

    private var activeService: any AIService {
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

    // MARK: - Public intents

    /// Sends a user message end-to-end. Awaits turn completion.
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        cancelActiveRequest(announce: false)
        if stateMachine.state == .error {
            _ = stateMachine.resetToIdle()
        }

        // Fast path: local facts + session controls, no AI involved.
        switch fastRouter.route(trimmed) {
        case .answer(let reply):
            await handleFastAnswer(userText: trimmed, reply: reply)
            return
        case .cancelCurrent:
            pushActivity(.init(kind: .system, title: "Nothing to cancel"))
            return
        case .mic(let action):
            messages.append(ConversationMessage(role: .user, text: trimmed))
            voiceControlHandler?(action)
            pushActivity(.init(kind: .listening, title: action == .enableMic ? "Mic requested on" : "Mic requested off"))
            return
        case .open(let request):
            messages.append(ConversationMessage(role: .user, text: trimmed))
            openURLHandler?(request)
            pushActivity(.init(kind: .system, title: "Opening \(request.label)"))
            return
        case .callContact(let name):
            messages.append(ConversationMessage(role: .user, text: trimmed))
            await handleContactCommand(name: name, makeRequest: OpenRequest.call)
            return
        case .messageContact(let name):
            messages.append(ConversationMessage(role: .user, text: trimmed))
            await handleContactCommand(name: name, makeRequest: OpenRequest.message)
            return
        case .whatsAppContact(let name):
            messages.append(ConversationMessage(role: .user, text: trimmed))
            await handleContactCommand(name: name, makeRequest: OpenRequest.whatsApp)
            return
        case .system(let action):
            messages.append(ConversationMessage(role: .user, text: trimmed))
            await handleSystemAction(action)
            return
        case .remind(let text, let dueDate):
            messages.append(ConversationMessage(role: .user, text: trimmed))
            await handleReminder(text: text, dueDate: dueDate)
            return
        case .myReminders:
            messages.append(ConversationMessage(role: .user, text: trimmed))
            await handleMyReminders()
            return
        case .none:
            break
        }

        let requestId = UUID()
        currentRequestId = requestId
        messages.append(ConversationMessage(role: .user, text: trimmed))
        pushActivity(.init(kind: .thinking, title: "Reasoning", detail: String(trimmed.prefix(120))))
        stateMachine.beginProcessing()

        // Bounded context: history + relevant memory + state + tools.
        let memories: [MemoryItem]
        if settings.memoryEnabled {
            memories = (try? await memoryService.search(query: trimmed, limit: contextManager.limits.maxMemories)) ?? []
        } else {
            memories = []
        }
        let availableTools = await toolRegistry.allTools().map { $0.name }
        let context = contextManager.build(
            history: messages,
            memories: memories,
            state: stateMachine.state,
            availableTools: availableTools,
            systemPrompt: AppConfig.systemPrompt
        )

        // Backend selected but unreachable-by-configuration → honest error, no network attempt.
        if settings.selectedProvider == .customBackend && !settings.backendConfig.isConfigured {
            let err = AppError.configuration("Backend not configured. Set the backend URL in Settings first.")
            finishFailed(requestId: requestId, error: err, userMessage: AssistantErrorMapper.userMessage(for: err))
            return
        }

        // Streaming placeholder the UI updates live.
        let placeholder = ConversationMessage(role: .assistant, text: "", timestamp: Date(), isStreaming: true)
        messages.append(placeholder)
        placeholderId[requestId] = placeholder.id
        lastSeq[requestId] = 0
        accumulated[requestId] = ""
        timingInFlight = RequestTiming(requestId: requestId) // T0 = dispatch
        isStreaming = true

        let aiRequest = AIRequest(
            id: requestId,
            text: trimmed,
            context: context,
            timeout: settings.requestTimeout
        )
        ZyraxisLogger.log(.ai, "send requestId=\(requestId) provider=\(activeService.provider.rawValue) contextMessages=\(context.messages.count)")

        // NOTE: the task captures only Sendable values (weak self + request).
        // The service is resolved inside runStream via activeService so the
        // non-Sendable `any AIService` existential never crosses into the
        // @Sendable task closure (Swift 6-safe).
        streamTask = Task { [weak self] in
            await self?.runStream(request: aiRequest)
        }
        await streamTask?.value
    }

    /// Entry point for future STT: final transcripts feed `send(_:)`.
    /// Partials only hint speaking state — never fabricated into messages.
    public func acceptExternalTranscript(_ text: String, isFinal: Bool) async {
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            voiceInitiatedTurn = !trimmed.isEmpty
            await send(text)
        } else if !text.isEmpty {
            stateMachine.markUserSpeaking()
        }
    }

    /// User-pressed Stop/Cancel: halt updates, notify service, return to idle.
    public func cancel() {
        cancelActiveRequest(announce: true)
    }

    public func clear() {
        cancelActiveRequest(announce: false)
        messages.removeAll()
        activities.removeAll()
    }

    /// Restores a previously snapshotted transcript (future persistence).
    public func restore(messages restored: [ConversationMessage]) {
        cancelActiveRequest(announce: false)
        messages = restored
    }

    public func snapshot() -> [ConversationMessage] { messages }

    /// Plain-text transcript export for the share sheet. Roles + text only
    /// (no timestamps — deterministic and unit-testable).
    public func exportText() -> String {
        messages.map { "[\($0.role.rawValue.uppercased())] \($0.text)" }.joined(separator: "\n")
    }

    public func pushActivity(_ activity: AssistantActivity) {
        activities.insert(activity, at: 0)
        if activities.count > 100 {
            activities = Array(activities.prefix(100))
        }
    }

    // MARK: - Stream driver

    private func runStream(request: AIRequest) async {
        let requestId = request.id
        // Resolve inside the task: `activeService` is a non-Sendable
        // existential and must never be captured by the @Sendable task above.
        let service = activeService
        do {
            for try await event in service.streamMessage(request) {
                try Task.checkCancellation()
                guard event.requestId == requestId, requestId == currentRequestId else {
                    // Stale event from a superseded/cancelled request — drop.
                    continue
                }
                await handle(event: event, requestId: requestId)
            }
            // Stream ended without a terminal event (service-dependent):
            // finalize only if this request is still current and incomplete.
            if requestId == currentRequestId {
                finishCompleted(requestId: requestId, text: accumulated[requestId] ?? "")
            }
        } catch is CancellationError {
            handleCancelled(requestId: requestId)
        } catch {
            handleFailure(requestId: requestId, error: error)
        }
    }

    private func handle(event: AIStreamEvent, requestId: UUID) async {
        markEventSeen(requestId: requestId, event: event)
        switch event {
        case .connected:
            pushActivity(.init(kind: .system, title: "Live session connected"))
        case .thinking:
            break // "Reasoning" activity already posted at send time.
        case .textDelta(_, let delta, let seq):
            guard seq > (lastSeq[requestId] ?? 0) else {
                ZyraxisLogger.log(.ai, "dropping duplicate/out-of-order delta seq=\(seq)")
                return
            }
            lastSeq[requestId] = seq
            accumulated[requestId, default: ""] += delta
            updatePlaceholder(requestId: requestId, text: accumulated[requestId] ?? "")
            if stateMachine.state == .processing {
                stateMachine.beginSpeaking()
            }
        case .toolCall(let req):
            if !stateMachine.beginExecuting() {
                // e.g. a delta already moved us to SPEAKING: route via idle.
                stateMachine.transition(to: .idle)
                stateMachine.beginExecuting()
            }
            pushActivity(.init(
                kind: .tool,
                title: "Tool requested: \(req.toolCall.toolName)"
            ))
            await executeToolRequest(req)
        case .toolResult(let res):
            pushActivity(.init(
                kind: .tool,
                title: res.succeeded ? "Tool ok: \(res.toolName)" : "Tool failed: \(res.toolName)",
                detail: res.error
            ))
        case .speaking:
            if stateMachine.state == .processing {
                stateMachine.beginSpeaking()
            }
        case .completed(_, let response):
            if !response.toolCalls.isEmpty && stateMachine.state != .executing {
                stateMachine.beginExecuting()
                pushActivity(.init(
                    kind: .tool,
                    title: "Tool calls returned (\(response.toolCalls.count))"
                ))
            }
            let final = response.text.isEmpty ? (accumulated[requestId] ?? "") : response.text
            finishCompleted(requestId: requestId, text: final)
        case .cancelled:
            handleCancelled(requestId: requestId)
        case .failed(_, let error):
            handleFailure(requestId: requestId, error: error)
        }
    }

    // MARK: - Timing (T1…T3 recorded per event, T4 at terminals)

    private func markEventSeen(requestId: UUID, event: AIStreamEvent) {
        guard var timing = timingInFlight, timing.requestId == requestId else { return }
        let now = ContinuousClock().now
        switch event {
        case .textDelta:
            if timing.t1Accepted == nil { timing.t1Accepted = now }
            if timing.t2FirstDelta == nil { timing.t2FirstDelta = now }
            timing.t3LastDelta = now
        case .completed, .failed, .cancelled:
            break // T4 is stamped by the terminal handlers below.
        default:
            if timing.t1Accepted == nil { timing.t1Accepted = now }
        }
        timingInFlight = timing
    }

    private func markDone(requestId: UUID) {
        guard var timing = timingInFlight, timing.requestId == requestId else { return }
        timing.t4Done = ContinuousClock().now
        timingInFlight = nil
        lastTiming = timing
    }

    // MARK: - Tool round-trip (client side)

    /// Handles a server `tool_call`: registry lookup → safe local execution
    /// (read-only, no-confirmation tools ONLY) → `tool_result` back to the
    /// server. Unregistered or unsafe tools yield a structured refusal result.
    /// No device-control tools are registered in Phase 3, so every call from a
    /// current backend correctly resolves to "unsupported tool".
    private func executeToolRequest(_ req: ToolCallRequest) async {
        guard req.requestId == currentRequestId else { return } // stale
        let name = req.toolCall.toolName
        guard let tool = await toolRegistry.tool(named: name) else {
            await returnToolResult(ToolCallResult(
                requestId: req.requestId,
                toolName: name,
                error: "unsupported tool: \(name)"
            ), activity: "Unsupported tool: \(name)")
            return
        }
        guard tool.riskLevel == .readOnly, !tool.requiresConfirmation else {
            await returnToolResult(ToolCallResult(
                requestId: req.requestId,
                toolName: name,
                error: "tool refused: \(name) requires confirmation or is not read-only"
            ), activity: "Tool refused (not read-only): \(name)")
            return
        }
        do {
            try Task.checkCancellation()
            let output = try await tool.execute(input: ToolInput(rawJSON: req.toolCall.argumentsJSON))
            guard req.requestId == currentRequestId else { return } // finished stale
            await returnToolResult(ToolCallResult(
                requestId: req.requestId,
                toolName: name,
                outputJSON: output.text
            ), activity: "Tool ok: \(name)")
        } catch {
            guard req.requestId == currentRequestId else { return }
            await returnToolResult(ToolCallResult(
                requestId: req.requestId,
                toolName: name,
                error: "tool failed: \(error.localizedDescription)"
            ), activity: "Tool failed: \(name)")
        }
    }

    private func returnToolResult(_ result: ToolCallResult, activity title: String) async {
        pushActivity(.init(
            kind: .tool,
            title: title,
            detail: result.error
        ))
        await activeService.sendToolResult(result)
    }

    // MARK: - Terminals

    private func finishCompleted(requestId: UUID, text: String) {
        guard requestId == currentRequestId else { return }
        markDone(requestId: requestId)
        updatePlaceholder(requestId: requestId, text: text, streaming: false)
        if stateMachine.state == .processing || stateMachine.state == .executing {
            stateMachine.beginSpeaking()
        }
        pushActivity(.init(kind: .speaking, title: "Responded"))
        // SPEAKING is momentary for text; with voice responses enabled the
        // SpeechService speaks the text in parallel (stopped on cancel).
        stateMachine.transition(to: .idle)
        teardown(requestId: requestId)
        ZyraxisLogger.log(.ai, "completed requestId=\(requestId) chars=\(text.count)")
        // Voice responses are opt-in (Settings). Text works standalone.
        if settings.voiceResponsesEnabled, !text.isEmpty {
            Task { [weak self] in
                await self?.speak(text)
            }
        }
        maybeAutoListen()
    }

    /// Resolves a contact name to a validated open request (call/text/chat).
    /// Honest at every step: missing service, denied permission, unknown name,
    /// and invalid numbers each produce a clear activity — never a blind dial.
    private func handleContactCommand(name: String, makeRequest: (String) -> OpenRequest?) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            pushActivity(.init(kind: .error, title: "No contact name given"))
            return
        }
        guard let directory = contactService else {
            pushActivity(.init(kind: .error, title: "Contacts unavailable on this build"))
            return
        }
        guard await directory.requestPermission() else {
            pushActivity(.init(
                kind: .error,
                title: "Contacts permission denied",
                detail: "Enable Contacts in iOS Settings to call or message by name."
            ))
            return
        }
        guard let digits = await directory.phoneNumber(for: trimmedName),
              let request = makeRequest(digits) else {
            pushActivity(.init(
                kind: .error,
                title: "Couldn't find '\(trimmedName)' in contacts",
                detail: "Use the full name as saved, or dictate the digits directly."
            ))
            return
        }
        openURLHandler?(request)
        pushActivity(.init(kind: .system, title: "Opening \(request.label)"))
    }

    /// Brightness change via system action handler (UI layer owns UIScreen).
    /// Volume is NOT settable by third-party apps — answered honestly in the router.
    private func handleSystemAction(_ action: SystemAction) async {
        systemActionHandler?(action)
    }

    /// Creates a reminder/task via TaskService (local with notifications).
    private func handleReminder(text: String, dueDate: Date?) async {
        guard let tasks = taskService else {
            pushActivity(.init(kind: .error, title: "Reminders unavailable on this build"))
            return
        }
        do {
            let task = try await tasks.create(title: text, notes: nil, dueDate: dueDate, priority: .medium)
            let when = dueDate.map { " for \(Self.timeString(from: $0))" } ?? ""
            pushActivity(.init(kind: .system, title: "Reminder set\(when): \(task.title)"))
        } catch {
            pushActivity(.init(kind: .error, title: "Couldn't create reminder", detail: error.localizedDescription))
        }
    }

    /// Reads back active reminders as a friendly assistant message.
    private func handleMyReminders() async {
        guard let tasks = taskService else {
            pushActivity(.init(kind: .error, title: "Reminders unavailable on this build"))
            return
        }
        do {
            let list = try await tasks.list(filter: .active)
            if list.isEmpty {
                pushActivity(.init(kind: .system, title: "No active reminders"))
            } else {
                let summary = list.prefix(5).map { "• \($0.title)\($0.dueDate.map { " — due \(Self.timeString(from: $0))" } ?? "")" }.joined(separator: "\n")
                await speak("You have \(list.count) active reminder\(list.count == 1 ? "" : "s"): \(summary)")
                pushActivity(.init(kind: .system, title: "Active reminders", detail: summary))
            }
        } catch {
            pushActivity(.init(kind: .error, title: "Couldn't read reminders", detail: error.localizedDescription))
        }
    }

    static func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Speaks via the wired SpeechService (nil by default → silent).
    private func speak(_ text: String) async {
        guard let speech = speechService else { return }
        let voiceId = settings.ttsVoiceIdentifier.isEmpty ? nil : settings.ttsVoiceIdentifier
        await speech.applyVoiceSettings(rate: settings.ttsRate, voiceIdentifier: voiceId)
        await speech.speak(text)
    }

    /// Hands-free re-listen: after a voice-initiated turn ends while the mode
    /// is on, ask the UI to reopen the mic. The flag is consumed here so a
    /// typed turn never re-arms it, and cancellation clears it (see below).
    private func maybeAutoListen() {
        guard settings.handsFreeMode, voiceInitiatedTurn else { return }
        voiceInitiatedTurn = false
        autoListenHandler?()
    }

    /// Stops any ongoing speech: no post-cancel and no previous-request
    /// speech, ever.
    private func stopSpeech() {
        guard speechService != nil else { return }
        Task { [weak self] in
            await self?.speechService?.stop()
        }
    }

    private func handleCancelled(requestId: UUID) {
        guard requestId == currentRequestId else { return }
        markDone(requestId: requestId)
        updatePlaceholder(requestId: requestId, text: accumulated[requestId] ?? "", streaming: false)
        stateMachine.transition(to: .idle)
        pushActivity(.init(kind: .system, title: "Request cancelled"))
        teardown(requestId: requestId)
        maybeAutoListen()
    }

    private func handleFailure(requestId: UUID, error: Error) {
        guard requestId == currentRequestId else { return }
        let friendly = AssistantErrorMapper.userMessage(for: error)
        finishFailed(requestId: requestId, error: AssistantErrorMapper.appError(for: error), userMessage: friendly)
        ZyraxisLogger.error(.ai, "request failed: \(AssistantErrorMapper.diagnostic(for: error))")
    }

    private func finishFailed(requestId: UUID, error: AppError, userMessage: String) {
        markDone(requestId: requestId)
        updatePlaceholder(requestId: requestId, text: "", streaming: false, removeIfEmpty: true)
        stateMachine.fail(with: error)
        messages.append(ConversationMessage(role: .system, text: userMessage))
        pushActivity(.init(kind: .error, title: "AI request failed", detail: userMessage))
        teardown(requestId: requestId)
        maybeAutoListen()
    }

    private func teardown(requestId: UUID) {
        if currentRequestId == requestId { currentRequestId = nil }
        isStreaming = false
        streamTask = nil
        lastSeq.removeValue(forKey: requestId)
        accumulated.removeValue(forKey: requestId)
        placeholderId.removeValue(forKey: requestId)
    }

    private func cancelActiveRequest(announce: Bool) {
        guard let id = currentRequestId else { return }
        currentRequestId = nil
        // Manual stop/new send ends hands-free chaining until the next
        // voice-initiated turn re-arms it.
        voiceInitiatedTurn = false
        streamTask?.cancel()
        streamTask = nil
        // Capture only the ID: the service existential is non-Sendable and
        // must be resolved inside the MainActor task, not captured by it.
        Task { [weak self, id] in
            await self?.activeService.cancelRequest(id: id)
        }
        markDone(requestId: id)
        stopSpeech()
        updatePlaceholder(requestId: id, text: accumulated[id] ?? "", streaming: false)
        isStreaming = false
        stateMachine.transition(to: .idle)
        if announce {
            pushActivity(.init(kind: .system, title: "Request cancelled"))
        }
        lastSeq.removeValue(forKey: id)
        accumulated.removeValue(forKey: id)
        placeholderId.removeValue(forKey: id)
    }

    // MARK: - Transcript helpers

    private func updatePlaceholder(requestId: UUID, text: String, streaming: Bool = true, removeIfEmpty: Bool = false) {
        guard let pid = placeholderId[requestId],
              let idx = messages.firstIndex(where: { $0.id == pid }) else { return }
        if removeIfEmpty && text.isEmpty {
            messages.remove(at: idx)
            return
        }
        messages[idx].text = text
        messages[idx].isStreaming = streaming
    }

    private func handleFastAnswer(userText: String, reply: String) async {
        if stateMachine.state == .error { _ = stateMachine.resetToIdle() }
        messages.append(ConversationMessage(role: .user, text: userText))
        stateMachine.beginProcessing()
        stateMachine.beginSpeaking()
        messages.append(ConversationMessage(role: .assistant, text: reply))
        pushActivity(.init(kind: .speaking, title: "Answered locally (fast path)"))
        stateMachine.transition(to: .idle)
        if settings.voiceResponsesEnabled {
            await speak(reply)
        }
    }
}
