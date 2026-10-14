import Foundation

// MARK: - Protocol version

/// Current iOS-side protocol version. The backend MUST echo this version.
/// Mismatched versions surface as a friendly "protocol mismatch" error —
/// never a crash, never silent misinterpretation.
public enum BackendProtocol {
    public static let currentVersion = 1
}

// MARK: - Message types

/// Wire message types between the iOS client and the ZYRAXIS backend.
/// Unknown raw values decode to `.unknown` (tolerated + ignored) so a newer
/// backend can add types without breaking this client.
public enum BackendMessageType: Equatable, Sendable {
    case sessionStart
    case sessionEnd
    case userMessage
    case assistantDelta
    case assistantComplete
    case assistantError
    case toolCall
    case toolResult
    case ping
    case pong
    case remoteCommand
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .sessionStart: return "session_start"
        case .sessionEnd: return "session_end"
        case .userMessage: return "user_message"
        case .assistantDelta: return "assistant_delta"
        case .assistantComplete: return "assistant_complete"
        case .assistantError: return "assistant_error"
        case .toolCall: return "tool_call"
        case .toolResult: return "tool_result"
        case .ping: return "ping"
        case .pong: return "pong"
        case .remoteCommand: return "remote_command"
        case .unknown(let s): return s
        }
    }

    public static func from(rawValue: String) -> BackendMessageType {
        switch rawValue {
        case "session_start": return .sessionStart
        case "session_end": return .sessionEnd
        case "user_message": return .userMessage
        case "assistant_delta": return .assistantDelta
        case "assistant_complete": return .assistantComplete
        case "assistant_error": return .assistantError
        case "tool_call": return .toolCall
        case "tool_result": return .toolResult
        case "ping": return .ping
        case "pong": return .pong
        case "remote_command": return .remoteCommand
        default: return .unknown(rawValue)
        }
    }
}

extension BackendMessageType: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = Self.from(rawValue: try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - JSON value

/// Minimal JSON value so envelopes carry typed payloads without `Any`.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw BackendProtocolError.malformedMessage("Undecodable JSON value.")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: Codable {}

// MARK: - Envelope

/// Versioned envelope for every frame: `{version, type, requestId, payload}`.
public struct ZyraxisEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var type: BackendMessageType
    public var requestId: String
    public var payload: [String: JSONValue]

    public init(
        type: BackendMessageType,
        requestId: String,
        payload: [String: JSONValue] = [:],
        version: Int = BackendProtocol.currentVersion
    ) {
        self.version = version
        self.type = type
        self.requestId = requestId
        self.payload = payload
    }

    /// Decodes a raw text frame. Throws version/malformed errors (never traps).
    public static func decode(_ text: String) throws -> ZyraxisEnvelope {
        guard let data = text.data(using: .utf8) else {
            throw BackendProtocolError.malformedMessage("Frame is not UTF-8 text.")
        }
        let env: ZyraxisEnvelope
        do {
            env = try JSONDecoder().decode(ZyraxisEnvelope.self, from: data)
        } catch {
            throw BackendProtocolError.malformedMessage("Envelope decoding failed: \(error.localizedDescription)")
        }
        guard env.version == BackendProtocol.currentVersion else {
            throw BackendProtocolError.versionMismatch(
                expected: BackendProtocol.currentVersion,
                received: env.version
            )
        }
        return env
    }

    public func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackendProtocolError.malformedMessage("Envelope encoding failed.")
        }
        return text
    }

    /// Typed payload access via JSON round-trip.
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            let data = try JSONEncoder().encode(payload)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackendProtocolError.malformedMessage("Payload decoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Payloads

public struct SessionStartPayload: Codable, Equatable, Sendable {
    public var sessionId: String
    public var clientModel: String?
    public var appVersion: String?
    public init(sessionId: String, clientModel: String? = nil, appVersion: String? = nil) {
        self.sessionId = sessionId
        self.clientModel = clientModel
        self.appVersion = appVersion
    }
}

public struct UserMessagePayload: Codable, Equatable, Sendable {
    public var text: String
    public var context: ConversationContext?
    public init(text: String, context: ConversationContext? = nil) {
        self.text = text
        self.context = context
    }
}

public struct AssistantDeltaPayload: Codable, Equatable, Sendable {
    /// 1-based sequence number per request. Lets the client drop duplicates
    /// and ignore stale/out-of-order chunks.
    public var delta: String
    public var seq: Int
    public init(delta: String, seq: Int) {
        self.delta = delta
        self.seq = seq
    }
}

public struct AssistantCompletePayload: Codable, Equatable, Sendable {
    public var fullText: String
    public var toolCalls: [ToolCall]
    public init(fullText: String, toolCalls: [ToolCall] = []) {
        self.fullText = fullText
        self.toolCalls = toolCalls
    }
}

public struct AssistantErrorPayload: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct ToolCallPayload: Codable, Equatable, Sendable {
    public var toolCall: ToolCall
    public var seq: Int
    public init(toolCall: ToolCall, seq: Int = 0) {
        self.toolCall = toolCall
        self.seq = seq
    }
}

public struct ToolResultPayload: Codable, Equatable, Sendable {
    public var toolName: String
    public var outputJSON: String
    public var error: String?
    public init(toolName: String, outputJSON: String = "{}", error: String? = nil) {
        self.toolName = toolName
        self.outputJSON = outputJSON
        self.error = error
    }
}

public struct PingPayload: Codable, Equatable, Sendable {
    public var timestamp: Double
    public init(timestamp: Double = Date().timeIntervalSince1970) {
        self.timestamp = timestamp
    }
}

/// Server-pushed command (dashboard → device). Executed only through the
/// conversation engine's fast-command path, so the same validation applies
/// as typed text — unvalidated input falls through to the AI, never to a
/// bypass. Carries no auth of its own: it is trusted because it arrives on
/// the already-authenticated server socket (dashboard itself is key-gated).
public struct RemoteCommandPayload: Codable, Equatable, Sendable {
    public var command: String
    public init(command: String) {
        self.command = command
    }
}

public enum BackendProtocolError: LocalizedError, Equatable, Sendable {
    case versionMismatch(expected: Int, received: Int)
    case malformedMessage(String)
    case unknownType(String)

    public var errorDescription: String? {
        switch self {
        case .versionMismatch(let e, let r):
            return "Backend protocol mismatch (client v\(e), server v\(r))."
        case .malformedMessage(let m):
            return "Malformed server message: \(m)"
        case .unknownType(let t):
            return "Unknown message type: \(t)"
        }
    }
}

// MARK: - Adapter layer

/// Translates wire envelopes into `AIStreamEvent`s.
///
/// The adapter exists so the iOS client never hardcodes assumptions about a
/// desktop backend's protocol: if the server speaks a different contract, a
/// new adapter implements this interface without touching the conversation
/// engine. Unknown types are ignored (tolerated); version mismatches throw.
public protocol BackendMessageAdapter: Sendable {
    func streamEvents(from envelope: ZyraxisEnvelope) throws -> [AIStreamEvent]
}

public struct ZyraxisV1Adapter: BackendMessageAdapter, Sendable {

    public init() {}

    public func streamEvents(from envelope: ZyraxisEnvelope) throws -> [AIStreamEvent] {
        guard let requestId = UUID(uuidString: envelope.requestId) else {
            throw BackendProtocolError.malformedMessage("requestId is not a UUID.")
        }
        switch envelope.type {
        case .sessionStart:
            return [.connected(requestId: requestId)]
        case .assistantDelta:
            let p = try envelope.decodePayload(AssistantDeltaPayload.self)
            return [.textDelta(requestId: requestId, delta: p.delta, seq: p.seq)]
        case .assistantComplete:
            let p = try envelope.decodePayload(AssistantCompletePayload.self)
            return [.completed(
                requestId: requestId,
                response: AIResponse(text: p.fullText, toolCalls: p.toolCalls, requestId: requestId)
            )]
        case .assistantError:
            let p = try envelope.decodePayload(AssistantErrorPayload.self)
            return [.failed(requestId: requestId, error: .ai("\(p.code): \(p.message)"))]
        case .toolCall:
            let p = try envelope.decodePayload(ToolCallPayload.self)
            return [.toolCall(request: ToolCallRequest(
                toolCall: p.toolCall,
                requestId: requestId
            ))]
        case .toolResult:
            let p = try envelope.decodePayload(ToolResultPayload.self)
            return [.toolResult(result: ToolCallResult(
                requestId: requestId,
                toolName: p.toolName,
                outputJSON: p.outputJSON,
                error: p.error
            ))]
        case .sessionEnd:
            return [.cancelled(requestId: requestId)]
        case .ping, .pong:
            // Transport-level keepalive — handled by the socket layer, not the AI layer.
            return []
        case .remoteCommand:
            // Server-pushed command — handled by BackendAIService's persistent
            // listener (request-scoped sinks drop it: its requestId is the
            // server's, never the in-flight turn's). Never surfaced as chat.
            return []
        case .userMessage:
            // Server echoing our own message — ignore client-side.
            return []
        case .unknown(let t):
            ZyraxisLogger.log(.websocket, "Ignoring unknown message type: \(t)")
            return []
        }
    }
}
