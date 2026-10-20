import Foundation

/// Direct Gemini calls with the user's own free-tier API key (AI Studio).
///
/// - Auth: key from Keychain (`KeychainKeys.geminiAPIKey`), sent ONLY as the
///   `x-goog-api-key` header — never in the URL, never logged.
/// - Non-streaming `sendMessage` via `:generateContent`.
/// - TRUE streaming `streamMessage` via `:streamGenerateContent` (SSE),
///   parsed incrementally — real token deltas, not canned replay.
/// - Timeouts from init; cancellation propagates; 401/429/5xx map to
///   `NetworkError`. Missing/empty key throws `.unauthorized` without any
///   network attempt.
/// - No WebSocket/audio: Gemini Live API is NOT implemented (see README).
@MainActor
public final class GeminiDirectService: @preconcurrency AIService {

    public let provider: AIProvider = .gemini

    /// Model ID, configurable (vendors rotate IDs — verify in AI Studio).
    public var model: String

    public private(set) var lastHttpStatus: Int?

    private let keychain: any KeychainService
    private let session: URLSession

    public init(
        keychain: any KeychainService = SystemKeychainService(),
        model: String = DirectProvider.defaultGeminiModel,
        timeout: TimeInterval = 30,
        session: URLSession? = nil
    ) {
        self.keychain = keychain
        self.model = model
        self.session = session ?? DirectProvider.session(timeout: timeout)
    }

    // MARK: - Key

    private func apiKey() throws -> String {
        guard let key = try? keychain.load(forKey: KeychainKeys.geminiAPIKey),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.unauthorized
        }
        return key
    }

    // MARK: - Request

    private struct ContentPart: Encodable {
        var text: String
    }

    private struct Content: Encodable {
        // Optional: systemInstruction carries no role per the documented
        // schema; content turns always set one.
        var role: String?
        var parts: [ContentPart]
    }

    private struct GenerationConfig: Encodable {
        var temperature: Double = 0.7
        /// The system prompt asks for "one or two small sentences", so a 1024
        /// cap just let a chatty model generate far more than it would speak —
        /// and every extra token is latency the user waits on. 512 still leaves
        /// plenty of room for a how-to answer.
        var maxOutputTokens: Int = 512
    }

    private struct GenerateBody: Encodable {
        var systemInstruction: Content
        var contents: [Content]
        var generationConfig = GenerationConfig()
    }

    private func makeRequest(streaming: Bool, request: AIRequest) throws -> URLRequest {
        let key = try apiKey()
        let action = streaming ? "streamGenerateContent" : "generateContent"
        var components = URLComponents(
            url: DirectProvider.geminiBaseURL
                .appendingPathComponent("v1beta/models/\(model):\(action)"),
            resolvingAgainstBaseURL: false
        )
        // API key travels ONLY in the x-goog-api-key header — never in the
        // URL (query params end up in logs/diagnostics).
        if streaming {
            components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        }
        guard let url = components?.url else {
            throw NetworkError.invalidURL("gemini \(action)")
        }
        let turns = DirectProvider.mergedTurns(context: request.context, currentText: request.text)
        // Gemini requires user-first alternating turns, but truncated history
        // can begin with a model turn. Drop leading model turns; the trailing
        // current-user turn guarantees a non-empty result either way.
        let leadingTrimmed = turns.drop(while: { $0.role == "assistant" })
        let effectiveTurns = leadingTrimmed.isEmpty
            ? [(role: "user", text: request.text)]
            : Array(leadingTrimmed)
        let contents = effectiveTurns.map { turn in
            Content(
                role: turn.role == "assistant" ? "model" : "user",
                parts: [ContentPart(text: turn.text)]
            )
        }
        let body = GenerateBody(
            systemInstruction: Content(
                role: nil,
                parts: [ContentPart(text: DirectProvider.systemText(context: request.context))]
            ),
            contents: contents
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct ResponseContent: Decodable {
                struct Part: Decodable {
                    var text: String?
                }
                var parts: [Part]?
            }
            var content: ResponseContent?
        }
        var candidates: [Candidate]?
        // promptFeedback intentionally ignored (block metadata, no secrets).
    }

    private static func extractText(_ response: GenerateResponse) throws -> String {
        let parts = response.candidates?.first?.content?.parts ?? []
        let text = parts.compactMap { $0.text }.joined()
        guard !text.isEmpty else {
            throw NetworkError.decoding("Gemini returned no usable text (possibly filtered).")
        }
        return text
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
        ZyraxisLogger.log(.ai, "gemini POST chat model=\(model)")
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
        let decoded: GenerateResponse
        do {
            decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw NetworkError.decoding(error.localizedDescription)
        }
        let text = try Self.extractText(decoded)
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
            ZyraxisLogger.log(.ai, "gemini SSE chat model=\(model)")
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
                let chunk: GenerateResponse
                do {
                    chunk = try JSONDecoder().decode(GenerateResponse.self, from: chunkData)
                } catch {
                    continue // One malformed SSE chunk never kills the stream.
                }
                let parts = chunk.candidates?.first?.content?.parts ?? []
                let delta = parts.compactMap { $0.text }.joined()
                guard !delta.isEmpty else { continue }
                seq += 1
                full += delta
                continuation.yield(.textDelta(requestId: requestId, delta: delta, seq: seq))
            }
            try Task.checkCancellation()
            guard !full.isEmpty else {
                throw NetworkError.decoding("Gemini streamed no usable text.")
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
