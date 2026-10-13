import Foundation

/// Direct Groq calls with the user's own free-tier API key (console.groq.com).
///
/// - Auth: key from Keychain (`KeychainKeys.groqAPIKey`) as a Bearer header.
/// - OpenAI-compatible `POST /openai/v1/chat/completions` (non-streaming and
///   `stream: true` SSE) — real token deltas, not canned replay.
/// - Timeouts from init; cancellation propagates; 401/429/5xx map to
///   `NetworkError`. Missing/empty key throws `.unauthorized` with no network.
/// - No WebSocket/audio path: Groq transcription is NOT implemented here.
@MainActor
public final class GroqDirectService: AIService {

    public let provider: AIProvider = .groq

    /// Model ID, configurable (verify live IDs on console.groq.com).
    public var model: String

    public private(set) var lastHttpStatus: Int?

    private let keychain: any KeychainService
    private let session: URLSession

    public init(
        keychain: any KeychainService = SystemKeychainService(),
        model: String = DirectProvider.defaultGroqModel,
        timeout: TimeInterval = 30,
        session: URLSession? = nil
    ) {
        self.keychain = keychain
        self.model = model
        self.session = session ?? DirectProvider.session(timeout: timeout)
    }

    // MARK: - Key

    private func apiKey() throws -> String {
        guard let key = try? keychain.load(forKey: KeychainKeys.groqAPIKey),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.unauthorized
        }
        return key
    }

    // MARK: - Request

    private struct ChatMessage: Encodable {
        var role: String
        var content: String
    }

    private struct ChatBody: Encodable {
        var model: String
        var messages: [ChatMessage]
        var temperature: Double = 0.7
        var maxTokens: Int = 1024
        var stream: Bool = false

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
            case stream
        }
    }

    private func makeRequest(streaming: Bool, request: AIRequest) throws -> URLRequest {
        let key = try apiKey()
        let turns = DirectProvider.mergedTurns(context: request.context, currentText: request.text)
        var messages = [ChatMessage(role: "system", content: DirectProvider.systemText(context: request.context))]
        messages += turns.map { ChatMessage(role: $0.role, content: $0.text) }
        let body = ChatBody(model: model, messages: messages, stream: streaming)
        var urlRequest = URLRequest(url: DirectProvider.groqChatURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }
            var message: Message?
        }
        var choices: [Choice]?
    }

    private struct ChatChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
            }
            var delta: Delta?
        }
        var choices: [Choice]?
    }

    private func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        lastHttpStatus = http.statusCode
        guard 200..<300 ~= http.statusCode else {
            let snippet = String(data: data.prefix(256), encoding: .utf8)
            throw DirectProvider.statusError(statusCode: http.statusCode, message: snippet)
        }
    }

    // MARK: - AIService

    public func sendMessage(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()
        let urlRequest = try makeRequest(streaming: false, request: request)
        ZyraxisLogger.log(.ai, "groq POST chat model=\(model)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw DirectProvider.transportError(error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport("Non-HTTP response.")
        }
        try checkStatus(http, data: data)
        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw NetworkError.decoding(error.localizedDescription)
        }
        guard let text = decoded.choices?.first?.message?.content, !text.isEmpty else {
            throw NetworkError.decoding("Groq returned no usable text.")
        }
        return AIResponse(text: text, requestId: request.id)
    }

    public func streamMessage(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runStream(request: request, continuation: continuation)
            }
        }
    }

    private func runStream(
        request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async {
        let requestId = request.id
        do {
            let urlRequest = try makeRequest(streaming: true, request: request)
            ZyraxisLogger.log(.ai, "groq SSE chat model=\(model)")
            continuation.yield(.connected(requestId: requestId))
            continuation.yield(.thinking(requestId: requestId))
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: urlRequest)
            } catch {
                throw DirectProvider.transportError(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.transport("Non-HTTP response.")
            }
            lastHttpStatus = http.statusCode
            guard 200..<300 ~= http.statusCode else {
                throw DirectProvider.statusError(statusCode: http.statusCode, message: nil)
            }
            var full = ""
            var seq = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let payload = DirectProvider.ssePayload(line) else { continue }
                guard let chunkData = payload.data(using: .utf8) else { continue }
                let chunk: ChatChunk
                do {
                    chunk = try JSONDecoder().decode(ChatChunk.self, from: chunkData)
                } catch {
                    continue // One malformed SSE chunk never kills the stream.
                }
                guard let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty else { continue }
                seq += 1
                full += delta
                continuation.yield(.textDelta(requestId: requestId, delta: delta, seq: seq))
            }
            try Task.checkCancellation()
            guard !full.isEmpty else {
                throw NetworkError.decoding("Groq streamed no usable text.")
            }
            continuation.yield(.completed(
                requestId: requestId,
                response: AIResponse(text: full, requestId: requestId)
            ))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
