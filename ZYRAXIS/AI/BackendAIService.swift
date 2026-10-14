import Foundation
import Combine

/// Supplies the backend bearer token at call time. Tokens live in Keychain
/// only — never in source, UserDefaults, or logs.
public protocol BackendAuthProvider: Sendable {
    func bearerToken() throws -> String?
}

public struct KeychainAuthProvider: BackendAuthProvider, Sendable {
    private let keychain: any KeychainService

    public init(keychain: any KeychainService) {
        self.keychain = keychain
    }

    public func bearerToken() throws -> String? {
        try keychain.load(forKey: KeychainKeys.backendAPIKey)
    }
}

/// Expected HTTP response for `POST {baseURL}/api/{apiVersion}/chat`.
///
/// This documents the iOS-side contract proposal. If the ZYRAXIS backend
/// speaks a different shape, evolve this DTO (or its path) — do not wedge
/// mismatched JSON into the conversation engine.
public struct BackendChatResponse: Codable, Equatable, Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var requestId: String?

    public init(text: String, toolCalls: [ToolCall] = [], requestId: String? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.requestId = requestId
    }
}

/// Real backend AI service (Phase 2): the iPhone is a thin client.
///
/// - Non-streaming `sendMessage` → HTTPS POST via `APIClient`.
/// - Streaming `streamMessage` → WebSocket envelopes via the shared socket,
///   mapped through a `BackendMessageAdapter` (default: `ZyraxisV1Adapter`).
/// - Provider credentials stay server-side; the app only presents the user's
///   own backend key (Keychain) as a Bearer token. No provider API keys exist
///   anywhere in this target.
/// - TLS/WSS validation is the URLSession default (never bypassed).
/// - Auth headers are built per request and never logged (see ZyraxisLogger).
@MainActor
public final class BackendAIService: @preconcurrency AIService {

    public let provider: AIProvider = .customBackend

    public var connectionState: ConnectionState { socket.state }

    private let socket: URLSessionWebSocketManager
    private let api: any APIClient
    private let auth: any BackendAuthProvider
    private let configProvider: () -> BackendConfig
    private let adapter: any BackendMessageAdapter
    /// Active frame subscriptions, one per in-flight request. ConversationManager
    /// serializes sends (single active request), so this stays tiny.
    private var streamSinks: [UUID: AnyCancellable] = [:]
    /// Server-pushed commands (dashboard → device). Invoked on the MainActor
    /// with the raw command text; the engine routes it through the normal
    /// fast-command path. Nil unless wired (tests leave it nil).
    public var remoteCommandHandler: ((String) -> Void)?
    /// Persistent unsolicited-frame listener. Per-request sinks only accept
    /// frames echoing their own requestId, so server-initiated frames (whose
    /// requestId is the server's) would otherwise have no receiver at all.
    /// Default-nil so `self` is fully formed before `init` captures it weakly.
    private var remoteSink: AnyCancellable? = nil
    /// Last observed HTTP status (for DEBUG diagnostics). Nil until the first
    /// chat POST completes.
    public private(set) var lastHttpStatus: Int?
    public private(set) var lastHttpAt: Date?

    public init(
        socket: URLSessionWebSocketManager,
        api: any APIClient,
        auth: any BackendAuthProvider,
        configProvider: @escaping () -> BackendConfig,
        adapter: any BackendMessageAdapter = ZyraxisV1Adapter()
    ) {
        self.socket = socket
        self.api = api
        self.auth = auth
        self.configProvider = configProvider
        self.adapter = adapter
        // Listen for server-pushed frames for the life of the service.
        // Everything except remote_command is ignored here — request-scoped
        // sinks own all the rest, so this never double-delivers.
        self.remoteSink = socket.incomingText.sink { [weak self] raw in
            Task { [weak self] in
                await self?.handleUnsolicitedFrame(raw)
            }
        }
    }

    // MARK: - Non-streaming (HTTPS)

    public func sendMessage(_ request: AIRequest) async throws -> AIResponse {
        let config = configProvider()
        guard config.isConfigured else {
            throw NetworkError.transport("Backend not configured. Set the backend URL in Settings.")
        }
        let requestId = request.id
        let ctx = request.context
        let body = ChatRequestBody(
            requestId: requestId.uuidString,
            text: request.text,
            context: ctx
        )
        let bodyData = try JSONEncoder().encode(body)
        var request = try api.makeRequest(
            path: "/api/\(config.apiVersion)/chat",
            method: "POST",
            body: bodyData,
            headers: [:]
        )
        try applyAuth(to: &request)
        ZyraxisLogger.log(.ai, "POST chat requestId=\(requestId)")
        let (data, http) = try await api.sendData(request)
        lastHttpStatus = http.statusCode
        lastHttpAt = Date()
        let response: BackendChatResponse
        do {
            response = try JSONDecoder().decode(BackendChatResponse.self, from: data)
        } catch {
            throw NetworkError.decoding(error.localizedDescription)
        }
        return AIResponse(text: response.text, toolCalls: response.toolCalls, requestId: requestId)
    }

    // MARK: - Streaming (WebSocket)

    public func streamMessage(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                await self?.runStream(request: request, continuation: continuation)
            }
        }
    }

    private func runStream(
        request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async {
        let config = configProvider()
        // Echo the engine's request ID in every envelope: stale-guard key.
        let requestId = request.id
        let ctx = request.context

        guard let wsURL = config.websocketURL else {
            continuation.finish(throwing: NetworkError.transport("WebSocket URL not configured. Set it in Settings."))
            return
        }
        // Client-synthesized transport signals (honest: these describe the
        // socket/request lifecycle, not model output).
        continuation.yield(.connected(requestId: requestId))

        if socket.state != .connected {
            socket.connect(url: wsURL)
        }
        do {
            try await socket.ping()
        } catch {
            continuation.finish(throwing: error)
            return
        }

        // Bridge socket frames → adapter events for THIS request only.
        // Stored on self: a local would deallocate (and cancel) on return.
        let adapter = adapter
        let sink = socket.incomingText.sink { [weak self] raw in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.handleFrame(raw, requestId: requestId, adapter: adapter, continuation: continuation)
            }
        }
        streamSinks[requestId] = sink
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.dropSink(for: requestId)
            }
        }

        let text = request.text
        do {
            try await sendEnvelope(type: .sessionStart, requestId: requestId, payload: SessionStartPayload(
                sessionId: requestId.uuidString,
                clientModel: ctx.device?.deviceModel,
                appVersion: ctx.device?.appVersion
            ))
            try await sendEnvelope(type: .userMessage, requestId: requestId, payload: UserMessagePayload(text: text, context: ctx))
            continuation.yield(.thinking(requestId: requestId))
            ZyraxisLogger.log(.websocket, "dispatched user_message requestId=\(requestId)")
        } catch {
            await dropSink(for: requestId)
            continuation.finish(throwing: error)
            return
        }
        // The stream stays open until the backend sends assistant_complete /
        // assistant_error, the consumer cancels, or cancelRequest ends it.
    }

    /// Receiver for server-initiated frames. Only `remote_command` is acted
    /// on; anything else (deltas for a live turn, pings, tool traffic) belongs
    /// to request-scoped handlers and is ignored here. A malformed command
    /// frame is logged and dropped — never executed, never crashed on.
    private func handleUnsolicitedFrame(_ raw: String) async {
        guard remoteCommandHandler != nil else { return }
        guard let envelope = try? ZyraxisEnvelope.decode(raw),
              envelope.type == .remoteCommand,
              let payload = try? envelope.decodePayload(RemoteCommandPayload.self) else { return }
        let command = payload.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        ZyraxisLogger.log(.websocket, "remote command received (\(command.prefix(60)))")
        remoteCommandHandler?(command)
    }

    private func handleFrame(
        _ raw: String,
        requestId: UUID,
        adapter: any BackendMessageAdapter,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async {
        let envelope: ZyraxisEnvelope
        do {
            envelope = try ZyraxisEnvelope.decode(raw)
        } catch {
            ZyraxisLogger.error(.websocket, "dropping undecodable frame: \(error.localizedDescription)")
            return // One bad frame never kills the stream.
        }
        // Answer server pings at the transport level.
        if envelope.type == .ping {
            let pong = ZyraxisEnvelope(type: .pong, requestId: envelope.requestId, payload: (try? Self.payload(PingPayload())) ?? [:])
            try? await socket.send(text: (try? pong.encode()) ?? "")
            return
        }
        guard envelope.requestId == requestId.uuidString else { return } // not ours
        do {
            let events = try adapter.streamEvents(from: envelope)
            for e in events {
                continuation.yield(e)
                switch e {
                case .completed, .failed, .cancelled:
                    await dropSink(for: requestId)
                    continuation.finish()
                    return
                default:
                    break
                }
            }
        } catch {
            ZyraxisLogger.error(.ai, "adapter error: \(error.localizedDescription)")
        }
    }

    public func cancelRequest(id: UUID) async {
        await dropSink(for: id)
        guard socket.state == .connected else { return }
        do {
            try await sendEnvelope(type: .sessionEnd, requestId: id, payload: SessionStartPayload(sessionId: id.uuidString))
            ZyraxisLogger.log(.websocket, "sent session_end requestId=\(id)")
        } catch {
            ZyraxisLogger.log(.websocket, "session_end send failed (best-effort)")
        }
    }

    /// Returns a locally-executed tool result to the server on the live
    /// socket. No-op when disconnected (best-effort — the server will time
    /// the tool call out on its side).
    public func sendToolResult(_ result: ToolCallResult) async {
        guard socket.state == .connected else {
            ZyraxisLogger.log(.tool, "tool_result dropped (socket not connected)")
            return
        }
        do {
            try await sendEnvelope(type: .toolResult, requestId: result.requestId, payload: ToolResultPayload(
                toolName: result.toolName,
                outputJSON: result.outputJSON,
                error: result.error
            ))
            ZyraxisLogger.log(.tool, "sent tool_result for \(result.toolName)")
        } catch {
            ZyraxisLogger.error(.tool, "tool_result send failed")
        }
    }

    private func dropSink(for requestId: UUID) {
        streamSinks.removeValue(forKey: requestId)
    }

    // MARK: - Private

    private func applyAuth(to request: inout URLRequest) throws {
        let token = try auth.bearerToken()
        guard let token, !token.isEmpty else {
            throw NetworkError.unauthorized
        }
        // Token material never leaves this function except into the header.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func sendEnvelope<T: Encodable>(type: BackendMessageType, requestId: UUID, payload: T) async throws {
        let env = ZyraxisEnvelope(type: type, requestId: requestId.uuidString, payload: (try? Self.payload(payload)) ?? [:])
        try await socket.send(text: env.encode())
    }

    /// Encodable → `[String: JSONValue]` via a JSON round-trip.
    static func payload<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            throw BackendProtocolError.malformedMessage("Payload is not a JSON object.")
        }
        return dict.compactMapValues(JSONValue.from(any:))
    }
}

private struct ChatRequestBody: Encodable {
    var requestId: String
    var text: String
    var context: ConversationContext?
}

private extension JSONValue {
    static func from(any value: Any) -> JSONValue? {
        switch value {
        case let s as String: return .string(s)
        case let n as NSNumber:
            // JSONSerialization booleans arrive as CFBoolean NSNumbers —
            // distinguish by type ID so 1/0 never become true/false.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case is NSNull: return .null
        case let a as [Any]: return .array(a.compactMap { from(any: $0) })
        case let o as [String: Any]: return .object(o.compactMapValues { from(any: $0) })
        default: return nil
        }
    }
}
