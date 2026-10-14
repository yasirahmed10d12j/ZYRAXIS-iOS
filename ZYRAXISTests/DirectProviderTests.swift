import XCTest
@testable import ZYRAXIS

/// In-memory Keychain double: never touches the real keychain on CI Macs.
/// Final class holding only Sendable state — no `@unchecked` needed.
/// Test-serial use only (XCTest runs methods serially by default).
final class InMemoryKeychain: KeychainService, Sendable {
    private var store: [String: String] = [:]

    func save(_ value: String, forKey key: String) throws {
        store[key] = value
    }

    func load(forKey key: String) throws -> String? {
        store[key]
    }

    func delete(forKey key: String) throws {
        store.removeValue(forKey: key)
    }
}

/// URLProtocol stub: deterministic responses, no network, no API credits.
/// Recorded requests prove what the services actually sent (headers, URLs).
final class StubURLProtocol: URLProtocol {

    struct Stub {
        var statusCode: Int = 200
        var data: Data = Data()
        var chunks: [Data]? = nil
        var error: URLError? = nil
        var delayNanoseconds: UInt64 = 0
    }

    static var handler: ((URLRequest) -> Stub?)?
    static var recordedRequests: [URLRequest] = []
    // Raw body bytes per recorded request, captured in startLoading (same
    // order as recordedRequests). URLSession moves httpBody into
    // httpBodyStream before the protocol sees it, so reading httpBody alone
    // yields nil — capture here instead of re-reading later.
    static var recordedBodies: [Data] = []
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)
        Self.recordedBodies.append(Self.captureBody(of: request))
        guard let stub = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if stub.delayNanoseconds > 0 {
            Thread.sleep(forTimeInterval: Double(stub.delayNanoseconds) / 1_000_000_000)
        }
        if cancelled {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if let chunks = stub.chunks, !chunks.isEmpty {
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
        } else {
            client?.urlProtocol(self, didLoad: stub.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        cancelled = true
    }

    static func reset() {
        handler = nil
        recordedRequests = []
        recordedBodies = []
    }

    /// Snapshot the request body at record time: prefer httpBody, else drain
    /// httpBodyStream once. Bounded reads (no hangs); consuming the stream is
    /// harmless here because stubbed responses are canned, never echoing it.
    private static func captureBody(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        var out = Data()
        stream.open()
        defer { stream.close() }
        var budget = 8 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while budget > 0, stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
            budget -= n
        }
        return out
    }
}

/// Direct Gemini + Groq provider tests. Every network touch goes through
/// `StubURLProtocol` — these tests spend no credits and need no keys.
@MainActor
final class DirectProviderTests: XCTestCase {

    private static let geminiKey = "test-gemini-key"
    private static let groqKey = "test-groq-key"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private static func keychainWithKeys() throws -> InMemoryKeychain {
        let kc = InMemoryKeychain()
        try kc.save(geminiKey, forKey: KeychainKeys.geminiAPIKey)
        try kc.save(groqKey, forKey: KeychainKeys.groqAPIKey)
        return kc
    }

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func geminiJSON(_ text: String) -> Data {
        """
        {"candidates":[{"content":{"parts":[{"text":"\(text)"}]}}]}
        """.data(using: .utf8)!
    }

    private static func groqJSON(_ text: String) -> Data {
        """
        {"choices":[{"message":{"role":"assistant","content":"\(text)"}}]}
        """.data(using: .utf8)!
    }

    private static func request(text: String = "hello") -> AIRequest {
        AIRequest(text: text, context: ConversationContext(systemPrompt: "sys"))
    }

    // MARK: - Provider metadata

    func testProviderCasesImplemented() {
        XCTAssertTrue(AIProvider.gemini.isImplemented)
        XCTAssertTrue(AIProvider.groq.isImplemented)
        XCTAssertFalse(AIProvider.realtimeFuture.isImplemented)
        XCTAssertFalse(AIProvider.gemini.displayName.isEmpty)
        XCTAssertFalse(AIProvider.groq.displayName.isEmpty)
        XCTAssertFalse(KeychainKeys.geminiAPIKey.isEmpty)
        XCTAssertFalse(KeychainKeys.groqAPIKey.isEmpty)
        XCTAssertNotEqual(KeychainKeys.geminiAPIKey, KeychainKeys.groqAPIKey)
        XCTAssertNotEqual(KeychainKeys.geminiAPIKey, KeychainKeys.backendAPIKey)
    }

    func testDefaultModelsNonEmpty() {
        XCTAssertFalse(DirectProvider.defaultGeminiModel.isEmpty)
        XCTAssertFalse(DirectProvider.defaultGroqModel.isEmpty)
        XCTAssertEqual(GeminiDirectService().model, DirectProvider.defaultGeminiModel)
        XCTAssertEqual(GroqDirectService().model, DirectProvider.defaultGroqModel)
    }

    func testDefaultGeminiModelIsSupportedStable() {
        // Pinned to a Stable, non-preview model with free-tier access and a
        // long support window. If Google retires it, update the default AND
        // this test together — never silently drift to an unverified ID.
        // Verified 2026-10-14: Stable, billing not required, shutdown no
        // earlier than 2027-07-21 (ai.google.dev/gemini-api/docs/models).
        XCTAssertEqual(DirectProvider.defaultGeminiModel, "gemini-3.5-flash-lite")
    }

    // MARK: - Prompt + SSE helpers

    func testMergedTurnsCollapseSameRole() {
        let ctx = ConversationContext(
            messages: [
                ConversationMessage(role: .user, text: "a"),
                ConversationMessage(role: .user, text: "b"),
                ConversationMessage(role: .assistant, text: "c"),
            ]
        )
        let turns = DirectProvider.mergedTurns(context: ctx, currentText: "d")
        XCTAssertEqual(turns.map { $0.role }, ["user", "assistant", "user"])
        XCTAssertTrue(turns[0].text.contains("a"))
        XCTAssertTrue(turns[0].text.contains("b"))
        XCTAssertTrue(turns[2].text.contains("d"))
    }

    func testSSEPayloadParsing() {
        XCTAssertEqual(DirectProvider.ssePayload("data: {\"a\":1}"), "{\"a\":1}")
        XCTAssertNil(DirectProvider.ssePayload(""))
        XCTAssertNil(DirectProvider.ssePayload(": comment"))
        XCTAssertNil(DirectProvider.ssePayload("data: "))
        XCTAssertNil(DirectProvider.ssePayload("data: [DONE]"))
        XCTAssertNil(DirectProvider.ssePayload("event: message"))
    }

    // MARK: - Gemini

    func testGeminiSendMessageSuccess() async throws {
        let session = Self.stubSession()
        let payload = Self.geminiJSON("Hi there")
        StubURLProtocol.handler = { _ in .init(data: payload) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        let response = try await svc.sendMessage(Self.request())
        XCTAssertEqual(response.text, "Hi there")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let sent = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(sent.url?.host, "generativelanguage.googleapis.com")
        XCTAssertTrue(sent.url?.path.contains("gemini-3.5-flash-lite:generateContent") == true)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-goog-api-key"), Self.geminiKey)
        // Key must never appear in the URL (query params end up in logs).
        XCTAssertFalse(sent.url?.absoluteString.contains(Self.geminiKey) == true)
    }

    private func sentBody() throws -> [String: Any] {
        _ = try XCTUnwrap(StubURLProtocol.recordedRequests.first, "no recorded request")
        let raw = try XCTUnwrap(StubURLProtocol.recordedBodies.first, "no captured body bytes")
        let json = try JSONSerialization.jsonObject(with: raw)
        return try XCTUnwrap(json as? [String: Any])
    }

    func testGeminiSystemInstructionHasNoRole() async throws {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(data: Self.geminiJSON("ok")) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        let ctx = ConversationContext(
            systemPrompt: "extra",
            messages: [ConversationMessage(role: .user, text: "hi")]
        )
        _ = try await svc.sendMessage(AIRequest(text: "hello", context: ctx))
        let body = try sentBody()
        let sys = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
        XCTAssertNil(sys["role"], "systemInstruction must not carry a role key")
        let parts = try XCTUnwrap(sys["parts"] as? [[String: Any]])
        XCTAssertFalse(parts.isEmpty)
    }

    func testGeminiDropsLeadingModelTurn() async throws {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(data: Self.geminiJSON("ok")) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        let ctx = ConversationContext(messages: [
            ConversationMessage(role: .assistant, text: "stale"),
            ConversationMessage(role: .user, text: "u1"),
        ])
        _ = try await svc.sendMessage(AIRequest(text: "current", context: ctx))
        let body = try sentBody()
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertFalse(contents.isEmpty)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        var roles: [String] = []
        var joined = ""
        for turn in contents {
            let role = try XCTUnwrap(turn["role"] as? String)
            roles.append(role)
            let parts = try XCTUnwrap(turn["parts"] as? [[String: Any]])
            joined += (parts.first?["text"] as? String) ?? ""
        }
        XCTAssertTrue(allAlternating(roles), "roles must alternate user/model: \(roles)")
        XCTAssertTrue(joined.contains("u1"))
        XCTAssertTrue(joined.contains("current"))
        XCTAssertFalse(joined.contains("stale"))
    }

    private func allAlternating(_ roles: [String]) -> Bool {
        guard let first = roles.first, first == "user" else { return false }
        return zip(roles, roles.dropFirst()).allSatisfy { $0 != $1 }
    }

    func testGeminiMissingKeyMakesNoNetworkCall() async {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(data: Data()) }
        let svc = GeminiDirectService(keychain: InMemoryKeychain(), session: session)
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected unauthorized")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .unauthorized)
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertTrue(AssistantErrorMapper.userMessage(for: NetworkError.unauthorized).contains("Settings"))
    }

    func testGeminiUnauthorizedMaps() async throws {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(statusCode: 401, data: Data()) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected unauthorized")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .unauthorized)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testGeminiRateLimitedMaps() async throws {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(statusCode: 429, data: Data()) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected rate limit")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .server(statusCode: 429, message: ""))
            XCTAssertTrue(AssistantErrorMapper.userMessage(for: e).contains("rate-limiting"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testGeminiServerErrorMaps() async throws {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(statusCode: 500, data: Data()) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected server error")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .server(statusCode: 500, message: ""))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testGeminiTimeoutMaps() async throws {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(error: URLError(.timedOut)) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected timeout")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .timeout)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testGeminiDecodingErrorMaps() async throws {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(data: Data("not json".utf8)) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected decoding error")
        } catch let e as NetworkError {
            guard case .decoding = e else {
                return XCTFail("expected decoding, got \(e)")
            }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testGeminiSendMessageCancellation() async throws {
        let session = Self.stubSession()
        let payload = Self.geminiJSON("late")
        StubURLProtocol.handler = { _ in .init(data: payload, delayNanoseconds: 2_000_000_000) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        let task = Task { try await svc.sendMessage(Self.request()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation propagates instead of surfacing as data.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testGeminiStreamsRealDeltas() async throws {let session = Self.stubSession()
        let chunk1 = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hel\"}]}}]}\n\n".data(using: .utf8)!
        let chunk2 = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"lo\"}]}}]}\n\n".data(using: .utf8)!
        StubURLProtocol.handler = { _ in .init(data: Data(), chunks: [chunk1, chunk2]) }
        let svc = GeminiDirectService(keychain: try Self.keychainWithKeys(), session: session)
        var events: [AIStreamEvent] = []
        for try await event in svc.streamMessage(Self.request()) {
            events.append(event)
        }
        // connected, thinking, 2 deltas, completed.
        XCTAssertEqual(events.count, 5)
        guard case .completed(_, let response)? = events.last else {
            return XCTFail("expected completed last, got \(events)")
        }
        XCTAssertEqual(response.text, "Hello")
        let deltas = events.compactMap { e -> (String, Int)? in
            if case .textDelta(_, let d, let s) = e { return (d, s) }
            return nil
        }
        XCTAssertEqual(deltas.map { $0.0 }, ["Hel", "lo"])
        XCTAssertEqual(deltas.map { $0.1 }, [1, 2])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertTrue(StubURLProtocol.recordedRequests[0].url?.path.contains("streamGenerateContent") == true)
    }

    // MARK: - Groq

    func testGroqSendMessageSuccess() async throws {
        let session = Self.stubSession()
        let payload = Self.groqJSON("Groq here")
        StubURLProtocol.handler = { _ in .init(data: payload) }
        let svc = GroqDirectService(keychain: try Self.keychainWithKeys(), session: session)
        let response = try await svc.sendMessage(Self.request())
        XCTAssertEqual(response.text, "Groq here")
        let sent = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(sent.url?.host, "api.groq.com")
        XCTAssertEqual(sent.url?.path, "/openai/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.groqKey)")
    }

    func testGroqMissingKeyMakesNoNetworkCall() async {
        let session = Self.stubSession()
        StubURLProtocol.handler = { _ in .init(data: Data()) }
        let svc = GroqDirectService(keychain: InMemoryKeychain(), session: session)
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected unauthorized")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .unauthorized)
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testGroqRateLimitedAndServerErrorsMap() async throws {
        let session = Self.stubSession()
        let svc = GroqDirectService(keychain: try Self.keychainWithKeys(), session: session)
        StubURLProtocol.handler = { _ in .init(statusCode: 429, data: Data()) }
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected 429")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .server(statusCode: 429, message: ""))
        } catch {
            XCTFail("wrong error \(error)")
        }
        StubURLProtocol.handler = { _ in .init(statusCode: 500, data: Data()) }
        do {
            _ = try await svc.sendMessage(Self.request())
            XCTFail("expected 500")
        } catch let e as NetworkError {
            XCTAssertEqual(e, .server(statusCode: 500, message: ""))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testGroqStreamsRealDeltas() async throws {
        let session = Self.stubSession()
        let chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n".data(using: .utf8)!
        let done = "data: [DONE]\n\n".data(using: .utf8)!
        StubURLProtocol.handler = { _ in .init(data: Data(), chunks: [chunk1, done]) }
        let svc = GroqDirectService(keychain: try Self.keychainWithKeys(), session: session)
        var events: [AIStreamEvent] = []
        for try await event in svc.streamMessage(Self.request()) {
            events.append(event)
        }
        guard case .completed(_, let response)? = events.last else {
            return XCTFail("expected completed last, got \(events)")
        }
        XCTAssertEqual(response.text, "Hi")
    }

    func testShortcutProviderSelection() {
        XCTAssertEqual(ShortcutProviderPolicy.pickProvider(geminiKey: "k", groqKey: "g"), .gemini)
        XCTAssertEqual(ShortcutProviderPolicy.pickProvider(geminiKey: nil, groqKey: "g"), .groq)
        XCTAssertEqual(ShortcutProviderPolicy.pickProvider(geminiKey: "  ", groqKey: nil), .none)
        XCTAssertEqual(ShortcutProviderPolicy.pickProvider(geminiKey: nil, groqKey: nil), .none)
        XCTAssertFalse(ShortcutProviderPolicy.setupDialog().isEmpty)
        XCTAssertFalse(ShortcutProviderPolicy.rateLimitDialog().isEmpty)
    }
}
